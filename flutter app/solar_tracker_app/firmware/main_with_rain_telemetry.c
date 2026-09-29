/*
 * Dual-axis LDR Solar Tracker with Rain Protection & INA219 Solar Output Monitoring
 * ATmega32 @ 1 MHz (raw DIP-40 chip)
 *
 * SENSOR MAP
 *   LDR1 = bottom-left  -> PA0 / ADC0 / physical pin 40
 *   LDR2 = bottom-right -> PA1 / ADC1 / physical pin 39
 *   LDR3 = top-left     -> PA2 / ADC2 / physical pin 38
 *   LDR4 = top-right    -> PA3 / ADC3 / physical pin 37
 *
 * SERVO MAP
 *   Azimuth   -> PD4 / OC1B / physical pin 18
 *   Elevation -> PD5 / OC1A / physical pin 19
 *
 * RAIN SENSOR MAP
 *   Rain Sensor D0 -> PB0 / physical pin 1
 *
 * DS18B20 WATERPROOF TEMPERATURE SENSOR (1-Wire)
 *   DS18B20 Data (yellow) -> PD2 / physical pin 16 (with 10kΩ external pull-up to VCC)
 *   DS18B20 VCC  (red)    -> 5 V
 *   DS18B20 GND  (black)  -> common GND
 *
 * BLUETOOTH / HC-05 MAP (UART 9600 baud)
 *   HC-05 TX -> PD0 / RXD / physical pin 14
 *   HC-05 RX -> PD1 / TXD / physical pin 15
 *
 * INA219 DC CURRENT/VOLTAGE SENSORS (Both sensors at default I2C address 0x40):
 *
 *   INA219 #1 (Solar Panel Input / Charging Side — Hardware TWI @ 50 kHz):
 *     SCL  -> PC0 / SCL / physical pin 22
 *     SDA  -> PC1 / SDA / physical pin 23
 *     VCC  -> +5 V regulated
 *     GND  -> common GND
 *     VIN+ -> solar panel positive
 *     VIN- -> charging/battery input positive
 *
 *   INA219 #2 (Battery / Load Output Side — Software I2C @ ~50 kHz):
 *     SCL  -> PC2 / physical pin 24
 *     SDA  -> PC3 / physical pin 25
 *     VCC  -> +5 V regulated
 *     GND  -> common GND
 *     VIN+ -> battery/load positive
 *     VIN- -> load circuit positive
 *
 * POWER
 *   ATmega VCC/AVCC, LDR dividers, INA219, and both servos share a regulated ~5 V
 *   rail (LM2596). Servos are powered from that rail, NOT from an I/O pin.
 *   ALL grounds (ATmega, LDR dividers, servos, INA219, USBasp) must be common.
 */


#define F_CPU 1000000UL

#include <avr/io.h>
#include <util/delay.h>
#include <stdint.h>

/* ================================================================
 *                     USER / MECHANICAL SETTINGS
 * ================================================================ */

/*
 * Use almost the full 1000..2000 us servo range, with a small safety
 * margin at each end. If either axis physically binds before these
 * points, reduce THAT axis's range immediately -- do not rely on the
 * servo's internal stop.
 */
#define AZ_MIN_CMD              2
#define AZ_MAX_CMD              220
#define EL_MIN_CMD              2
#define EL_MAX_CMD              220

#define AZ_START_CMD            90
#define EL_START_CMD            90

/* Flip 0 -> 1 if that axis moves AWAY from the light source. */
#define AZ_REVERSED             1
#define EL_REVERSED             0

/* Known-good hobby-servo pulse window from prior bench testing. */
#define SERVO_MIN_US            1000U
#define SERVO_MAX_US            2000U

/* ================================================================
 *                 DUAL INA219 SENSOR SETTINGS
 * ================================================================ */

/*
 * Both INA219 sensors operate at default 7-bit I2C address 0x40.
 * Bus 1: Hardware TWI (PC0 SCL pin 22, PC1 SDA pin 23) -> Solar Input
 * Bus 2: Software I2C (PC2 SCL pin 24, PC3 SDA pin 25) -> Battery/Load Output
 */
#define INA219_I2C_ADDR         0x40
#define INA219_I2C_ADDR_W       ((INA219_I2C_ADDR << 1) | 0) /* 0x80 */
#define INA219_I2C_ADDR_R       ((INA219_I2C_ADDR << 1) | 1) /* 0x81 */

/* Update measurements approximately once every 1 second (1000 ms / CONTROL_DELAY_MS) */
#define INA219_REPORT_LOOPS     (1000 / CONTROL_DELAY_MS)

/* ================================================================
 *                     RAIN SENSOR SETTINGS
 * ================================================================ */

/* Rain sensor digital output D0 connected to PB0 (physical pin 1 on ATmega32) */
#define RAIN_PIN                PB0

/*
 * Active LOW: Standard LM393 rain sensor modules output LOW (0) when water
 * is detected on the sensor board, and HIGH (1) when dry.
 * If your sensor module outputs HIGH when rain is detected, set this to 0.
 */
#define RAIN_ACTIVE_LOW         1

/*
 * Vertical stow angle for rain protection:
 * Tilts the solar panel vertical (90 degrees to ground) so rain runs off
 * and causes minimum impact on the panel.
 * Default is EL_MIN_CMD (2). If your physical frame tilts vertical at
 * EL_MAX_CMD (220), change this to EL_MAX_CMD.
 */
#define EL_RAIN_VERTICAL_CMD    EL_MIN_CMD

/* Set to 1 to also center azimuth (AZ_START_CMD) in the rain, 0 to keep current azimuth */
#define AZ_RAIN_CENTER_ENABLED  0

/* ================================================================
 *                  DS18B20 TEMPERATURE SENSOR SETTINGS
 * ================================================================ */

/*
 * DS18B20 1-Wire data pin connected to PD2 (physical pin 16 on ATmega32).
 * An external 10kΩ pull-up resistor is wired between the data pin and VCC.
 * The internal pull-up is NOT used — the external resistor handles it.
 */
#define DS18B20_DDR     DDRD
#define DS18B20_PORT    PORTD
#define DS18B20_PINREG  PIND
#define DS18B20_BIT     PD2

/* Threshold above which excessive heat alert is transmitted to mobile via Bluetooth */
#define TEMP_WARNING_THRESHOLD_C 40

/* ================================================================
 *                     PANEL-ALIGNMENT CALIBRATION
 * ================================================================ */

/* Keep this 1 for the current prototype / flashlight testing. */
#define ENABLE_BOOT_PANEL_CALIBRATION   1

/* Samples are spread over time so one noisy instant doesn't define bias. */
#define CALIBRATION_SAMPLES             64
#define CALIBRATION_SAMPLE_DELAY_MS     10

/*
 * Optional small manual correction AFTER automatic calibration.
 * Error scale: 1000 = 100%, 10 = 1%. Leave at zero first; if a small
 * repeatable offset remains after testing, nudge by +10/-10/+20/-20
 * rather than changing servo geometry in code.
 */
#define HORIZONTAL_MANUAL_TRIM          0
#define VERTICAL_MANUAL_TRIM            0

/* Reject absurd startup calibration values from a badly aimed lamp. */
#define MAX_LEARNED_BIAS                450
#define MIN_CALIBRATION_LIGHT_ADC       70

/* ================================================================
 *                         TRACKING SETTINGS
 * ================================================================ */

/*
 * Normalized error scale: 1000 = 100% imbalance, 100 = 10%, 50 = 5%.
 *
 * Hysteresis: movement STARTS once |error| exceeds START_ERROR and
 * STOPS once |error| falls back inside STOP_ERROR. This asymmetry is
 * what prevents constant twitching around the target.
 */
#define START_ERROR                     60
#define STOP_ERROR                      25

/* Adaptive motion: larger steps far away, gentle steps near alignment. */
#define STEP_VERY_FAR                   4
#define STEP_FAR                        3
#define STEP_MEDIUM                     2
#define STEP_FINE                       1

/* One control decision per servo frame. */
#define CONTROL_DELAY_MS                40

/* Small local ADC averaging only -- no sluggish long-term filter. */
#define ADC_SAMPLES                     16

/* Do not chase ADC noise when the whole scene is dark. */
#define MIN_TRACKING_LIGHT_ADC          55

/* Slow to 1-unit steps within this many command units of a limit. */
#define EDGE_SLOW_ZONE                  10

/* ================================================================
 *                           GLOBAL STATE
 * ================================================================ */

static uint8_t azimuth_cmd   = AZ_START_CMD;
static uint8_t elevation_cmd = EL_START_CMD;

static int8_t azimuth_state   = 0;   /* -1 = CW, 0 = holding, +1 = CCW  */
static int8_t elevation_state = 0;

/* Learned normalized errors for when the PANEL (not the LDR head) is optimal. */
static int16_t horizontal_target_error = 0;
static int16_t vertical_target_error   = 0;

/* ================================================================
 *                                ADC
 * ================================================================ */

static void adc_init(void)
{
    /* PA0..PA3 as analog inputs, no internal pull-ups. */
    DDRA  &= (uint8_t)~0x0F;
    PORTA &= (uint8_t)~0x0F;

    /* AVCC as ADC reference, right-adjusted 10-bit result. */
    ADMUX = (1 << REFS0);

    /* Enable ADC, prescaler = 8 -> 1 MHz / 8 = 125 kHz ADC clock. */
    ADCSRA =
          (1 << ADEN)
        | (1 << ADPS1)
        | (1 << ADPS0);

    /* Discard the first ("warm-up") conversion. */
    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC))
    {
        ;
    }
    (void)ADCW;
}

static uint16_t adc_read_once(uint8_t channel)
{
    /* MUX4:0 lives in ADMUX[4:0]; REFS1:0 (bits 7:6) and ADLAR (bit5) are
     * preserved. Only channels 0-7 are used here, so masking to 5 bits
     * is safe and matches the full MUX field width. */
    ADMUX = (uint8_t)((ADMUX & 0xE0) | (channel & 0x1F));

    /* Short settling time after switching the ADC input. */
    _delay_us(8);

    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC))
    {
        ;
    }

    return ADCW;
}

static uint16_t adc_read(uint8_t channel)
{
    uint32_t sum = 0;
    uint8_t i;

    /* Discard the first reading right after changing channels. */
    (void)adc_read_once(channel);

    for (i = 0; i < ADC_SAMPLES; i++)
    {
        sum += adc_read_once(channel);
    }

    return (uint16_t)(sum / ADC_SAMPLES);
}

/* ================================================================
 *                            SERVO PWM
 * ================================================================ */

static uint16_t command_to_pulse(uint8_t command)
{
    return (uint16_t)(
        SERVO_MIN_US
        + (((uint32_t)(SERVO_MAX_US - SERVO_MIN_US) * command) / 180UL)
    );
}

static void servo_init(void)
{
    /* PD4 = OC1B = azimuth; PD5 = OC1A = elevation. */
    DDRD |= (1 << PD4) | (1 << PD5);

    TCCR1A = 0;
    TCCR1B = 0;
    TCNT1  = 0;

    /* Timer tick = 1 us at F_CPU = 1 MHz, prescaler = 1.
     * 20,000 us period -> 50 Hz servo frame. */
    ICR1 = 19999;

    OCR1B = command_to_pulse(AZ_START_CMD);
    OCR1A = command_to_pulse(EL_START_CMD);

    /* Fast PWM mode 14 (TOP = ICR1), non-inverting on OC1A/OC1B. */
    TCCR1A =
          (1 << COM1A1)
        | (1 << COM1B1)
        | (1 << WGM11);

    TCCR1B =
          (1 << WGM13)
        | (1 << WGM12)
        | (1 << CS10);
}

/* ================================================================
 *                       LIGHT / ERROR HELPERS
 * ================================================================ */

static int16_t relative_error(uint16_t a, uint16_t b)
{
    uint16_t sum = (uint16_t)(a + b);

    if (sum < 10)
    {
        return 0;
    }

    return (int16_t)(
        (((int32_t)a - (int32_t)b) * 1000L) / (int32_t)sum
    );
}

static uint16_t abs16(int16_t value)
{
    if (value < 0)
    {
        return (uint16_t)(-value);
    }

    return (uint16_t)value;
}

static int16_t clamp_i16(int16_t value, int16_t lo, int16_t hi)
{
    if (value < lo)
    {
        return lo;
    }

    if (value > hi)
    {
        return hi;
    }

    return value;
}

static void read_directional_values(
    uint16_t *ldr1,
    uint16_t *ldr2,
    uint16_t *ldr3,
    uint16_t *ldr4,
    uint16_t *left,
    uint16_t *right,
    uint16_t *top,
    uint16_t *bottom)
{
    *ldr1 = adc_read(0);   /* bottom-left  */
    *ldr2 = adc_read(1);   /* bottom-right */
    *ldr3 = adc_read(2);   /* top-left     */
    *ldr4 = adc_read(3);   /* top-right    */

    *left   = (uint16_t)(((uint32_t)(*ldr1) + (*ldr3)) / 2UL);
    *right  = (uint16_t)(((uint32_t)(*ldr2) + (*ldr4)) / 2UL);
    *top    = (uint16_t)(((uint32_t)(*ldr3) + (*ldr4)) / 2UL);
    *bottom = (uint16_t)(((uint32_t)(*ldr1) + (*ldr2)) / 2UL);
}

/* ================================================================
 *                  PANEL-TO-SENSOR ALIGNMENT LEARNING
 * ================================================================ */

static void calibrate_panel_alignment(void)
{
#if ENABLE_BOOT_PANEL_CALIBRATION
    uint8_t i;
    int32_t horizontal_sum = 0;
    int32_t vertical_sum = 0;
    uint32_t light_sum = 0;

    uint16_t ldr1, ldr2, ldr3, ldr4;
    uint16_t left, right, top, bottom;

    /*
     * Servos have already centered. Keep the light aimed at the PANEL
     * center during this window -- the code learns what the LDR pattern
     * looks like when the panel itself is correctly aimed.
     */
    for (i = 0; i < CALIBRATION_SAMPLES; i++)
    {
        read_directional_values(
            &ldr1, &ldr2, &ldr3, &ldr4,
            &left, &right, &top, &bottom
        );

        horizontal_sum += relative_error(left, right);
        vertical_sum   += relative_error(top, bottom);

        light_sum +=
            ((uint32_t)ldr1 + ldr2 + ldr3 + ldr4) / 4UL;

        _delay_ms(CALIBRATION_SAMPLE_DELAY_MS);
    }

    /* Only accept the learned bias if calibration happened in enough light. */
    if ((light_sum / CALIBRATION_SAMPLES) >= MIN_CALIBRATION_LIGHT_ADC)
    {
        horizontal_target_error = (int16_t)(
            horizontal_sum / CALIBRATION_SAMPLES
        );

        vertical_target_error = (int16_t)(
            vertical_sum / CALIBRATION_SAMPLES
        );

        horizontal_target_error = clamp_i16(
            horizontal_target_error,
            -MAX_LEARNED_BIAS,
            MAX_LEARNED_BIAS
        );

        vertical_target_error = clamp_i16(
            vertical_target_error,
            -MAX_LEARNED_BIAS,
            MAX_LEARNED_BIAS
        );
    }
    else
    {
        /* Dark/invalid startup: fall back to ordinary zero-error tracking. */
        horizontal_target_error = 0;
        vertical_target_error   = 0;
    }
#endif

    horizontal_target_error += HORIZONTAL_MANUAL_TRIM;
    vertical_target_error   += VERTICAL_MANUAL_TRIM;
}

/* ================================================================
 *                    ANTI-TWITCH / ADAPTIVE MOTION
 * ================================================================ */

static int8_t update_motion_state(int16_t error, int8_t current_state)
{
    if (current_state == 0)
    {
        if (error >= START_ERROR)
        {
            return +1;
        }

        if (error <= -START_ERROR)
        {
            return -1;
        }

        return 0;
    }

    if (current_state > 0)
    {
        /* Stop first on crossing/entering the target band; don't snap-reverse. */
        if (error <= STOP_ERROR)
        {
            return 0;
        }

        return +1;
    }

    if (error >= -STOP_ERROR)
    {
        return 0;
    }

    return -1;
}

static uint8_t adaptive_step(int16_t error)
{
    uint16_t e = abs16(error);

    if (e >= 260)
    {
        return STEP_VERY_FAR;
    }

    if (e >= 160)
    {
        return STEP_FAR;
    }

    if (e >= 90)
    {
        return STEP_MEDIUM;
    }

    return STEP_FINE;
}

static uint8_t slow_near_azimuth_edge(uint8_t step)
{
    if (azimuth_cmd <= (AZ_MIN_CMD + EDGE_SLOW_ZONE) ||
        azimuth_cmd >= (AZ_MAX_CMD - EDGE_SLOW_ZONE))
    {
        return 1;
    }

    return step;
}

static uint8_t slow_near_elevation_edge(uint8_t step)
{
    if (elevation_cmd <= (EL_MIN_CMD + EDGE_SLOW_ZONE) ||
        elevation_cmd >= (EL_MAX_CMD - EDGE_SLOW_ZONE))
    {
        return 1;
    }

    return step;
}

static void move_azimuth(int8_t direction, uint8_t step)
{
    int16_t target;

#if AZ_REVERSED
    direction = (int8_t)(-direction);
#endif

    if (direction == 0)
    {
        return;
    }

    step = slow_near_azimuth_edge(step);

    target = (int16_t)azimuth_cmd + ((int16_t)direction * step);

    if (target < AZ_MIN_CMD)
    {
        target = AZ_MIN_CMD;
    }

    if (target > AZ_MAX_CMD)
    {
        target = AZ_MAX_CMD;
    }

    if ((uint8_t)target != azimuth_cmd)
    {
        azimuth_cmd = (uint8_t)target;
        OCR1B = command_to_pulse(azimuth_cmd);
    }
}

static void move_elevation(int8_t direction, uint8_t step)
{
    int16_t target;

#if EL_REVERSED
    direction = (int8_t)(-direction);
#endif

    if (direction == 0)
    {
        return;
    }

    step = slow_near_elevation_edge(step);

    target = (int16_t)elevation_cmd + ((int16_t)direction * step);

    if (target < EL_MIN_CMD)
    {
        target = EL_MIN_CMD;
    }

    if (target > EL_MAX_CMD)
    {
        target = EL_MAX_CMD;
    }

    if ((uint8_t)target != elevation_cmd)
    {
        elevation_cmd = (uint8_t)target;
        OCR1A = command_to_pulse(elevation_cmd);
    }
}

/* ================================================================
 *                              UART
 * ================================================================ */

static void uart_init(void)
{
    /* Double speed mode */
    UCSRA |= (1 << U2X);

    /* 9600 baud @ 1MHz */
    UBRRH = 0;
    UBRRL = 12;

    /* Enable receiver and transmitter */
    UCSRB = (1 << RXEN) | (1 << TXEN);

    /* 8-bit data, 1 stop bit */
    UCSRC = (1 << URSEL) | (1 << UCSZ1) | (1 << UCSZ0);
}

static char uart_receive_non_blocking(void)
{
    if (UCSRA & (1 << RXC))
    {
        return UDR;
    }
    return 0;
}

static void uart_send_char(char c)
{
    while (!(UCSRA & (1 << UDRE)))
    {
        ;
    }
    UDR = c;
}

static void uart_send_string(const char *str)
{
    while (*str)
    {
        uart_send_char(*str);
        str++;
    }
}

static void uart_send_uint(uint32_t num)
{
    char buf[11];
    uint8_t i = 0;

    if (num == 0)
    {
        uart_send_char('0');
        return;
    }

    while (num > 0)
    {
        buf[i++] = (char)('0' + (num % 10));
        num /= 10;
    }

    while (i > 0)
    {
        uart_send_char(buf[--i]);
    }
}

/* ================================================================
 *                          RAIN SENSOR
 * ================================================================ */

static void rain_sensor_init(void)
{
    /* PB0 as digital input */
    DDRB &= (uint8_t)~(1 << RAIN_PIN);

    /* Enable internal pull-up on PB0 */
    PORTB |= (uint8_t)(1 << RAIN_PIN);
}

static uint8_t is_rain_detected(void)
{
#if RAIN_ACTIVE_LOW
    return !(PINB & (1 << RAIN_PIN));
#else
    return !!(PINB & (1 << RAIN_PIN));
#endif
}

/* App telemetry only: no changes to rain policy or servo calibration. */
static void report_rain_status(uint8_t raining, char mode)
{
    if (!raining)
        uart_send_string("Rain: Dry\r\n");
    else if (mode == 'A')
        uart_send_string("Rain: Detected; Tracking stopped\r\n");
    else
        uart_send_string("Rain: Detected\r\n");
}

static void set_elevation_target(uint8_t target_cmd)
{
    if (target_cmd < EL_MIN_CMD)
    {
        target_cmd = EL_MIN_CMD;
    }
    if (target_cmd > EL_MAX_CMD)
    {
        target_cmd = EL_MAX_CMD;
    }

    if (elevation_cmd < target_cmd)
    {
        uint8_t diff = (uint8_t)(target_cmd - elevation_cmd);
        uint8_t step = (diff > STEP_VERY_FAR) ? STEP_VERY_FAR : diff;
        elevation_cmd += step;
        OCR1A = command_to_pulse(elevation_cmd);
    }
    else if (elevation_cmd > target_cmd)
    {
        uint8_t diff = (uint8_t)(elevation_cmd - target_cmd);
        uint8_t step = (diff > STEP_VERY_FAR) ? STEP_VERY_FAR : diff;
        elevation_cmd -= step;
        OCR1A = command_to_pulse(elevation_cmd);
    }
}

#if AZ_RAIN_CENTER_ENABLED
static void set_azimuth_target(uint8_t target_cmd)
{
    if (target_cmd < AZ_MIN_CMD)
    {
        target_cmd = AZ_MIN_CMD;
    }
    if (target_cmd > AZ_MAX_CMD)
    {
        target_cmd = AZ_MAX_CMD;
    }

    if (azimuth_cmd < target_cmd)
    {
        uint8_t diff = (uint8_t)(target_cmd - azimuth_cmd);
        uint8_t step = (diff > STEP_VERY_FAR) ? STEP_VERY_FAR : diff;
        azimuth_cmd += step;
        OCR1B = command_to_pulse(azimuth_cmd);
    }
    else if (azimuth_cmd > target_cmd)
    {
        uint8_t diff = (uint8_t)(azimuth_cmd - target_cmd);
        uint8_t step = (diff > STEP_VERY_FAR) ? STEP_VERY_FAR : diff;
        azimuth_cmd -= step;
        OCR1B = command_to_pulse(azimuth_cmd);
    }
}
#endif

/* ================================================================
 *                   1-WIRE PROTOCOL (BIT-BANG)
 * ================================================================ */

/*
 * Minimal 1-Wire master for DS18B20.
 * Timing is tuned for F_CPU = 1 MHz (1 µs per CPU cycle).
 * The external 10 kΩ pull-up on the data line handles bus release.
 */

static uint8_t ow_reset(void)
{
    uint8_t presence;

    /* Pull bus low for ≥480 µs (reset pulse). */
    DS18B20_DDR  |= (uint8_t)(1 << DS18B20_BIT);     /* output  */
    DS18B20_PORT &= (uint8_t)~(1 << DS18B20_BIT);    /* low     */
    _delay_us(480);

    /* Release bus, wait 60-70 µs, then sample for presence pulse. */
    DS18B20_DDR  &= (uint8_t)~(1 << DS18B20_BIT);    /* input   */
    _delay_us(70);
    presence = !(DS18B20_PINREG & (1 << DS18B20_BIT));

    /* Wait for the rest of the 480 µs slot after release. */
    _delay_us(410);

    return presence;   /* 1 = device present, 0 = no device */
}

static void ow_write_bit(uint8_t bit)
{
    DS18B20_DDR  |= (uint8_t)(1 << DS18B20_BIT);     /* output  */
    DS18B20_PORT &= (uint8_t)~(1 << DS18B20_BIT);    /* low     */

    if (bit)
    {
        _delay_us(6);
        DS18B20_DDR &= (uint8_t)~(1 << DS18B20_BIT); /* release */
        _delay_us(64);
    }
    else
    {
        _delay_us(60);
        DS18B20_DDR &= (uint8_t)~(1 << DS18B20_BIT); /* release */
        _delay_us(10);
    }
}

static uint8_t ow_read_bit(void)
{
    uint8_t bit;

    DS18B20_DDR  |= (uint8_t)(1 << DS18B20_BIT);     /* output  */
    DS18B20_PORT &= (uint8_t)~(1 << DS18B20_BIT);    /* low     */
    _delay_us(6);

    DS18B20_DDR  &= (uint8_t)~(1 << DS18B20_BIT);    /* release */
    _delay_us(9);
    bit = !!(DS18B20_PINREG & (1 << DS18B20_BIT));

    _delay_us(55);
    return bit;
}

static void ow_write_byte(uint8_t data)
{
    uint8_t i;

    for (i = 0; i < 8; i++)
    {
        ow_write_bit(data & 0x01);
        data >>= 1;
    }
}

static uint8_t ow_read_byte(void)
{
    uint8_t i;
    uint8_t data = 0;

    for (i = 0; i < 8; i++)
    {
        data >>= 1;
        if (ow_read_bit())
        {
            data |= 0x80;
        }
    }

    return data;
}

/* ================================================================
 *                       DS18B20 DRIVER
 * ================================================================ */

/*
 * Two-phase usage from the main loop:
 *   Phase 1: ds18b20_start_conversion()   — sends Convert T command
 *   Phase 2: ds18b20_report()             — reads scratchpad & prints
 * The caller must wait ≥750 ms between the two phases (12-bit default).
 * Our ~1 s report cycle satisfies this easily.
 */

static uint8_t ds18b20_start_conversion(void)
{
    if (!ow_reset())
    {
        return 0;
    }

    ow_write_byte(0xCC);   /* Skip ROM (only one sensor on the bus) */
    ow_write_byte(0x44);   /* Convert T */
    return 1;
}

static uint8_t ds18b20_read_temperature(int16_t *raw_temp)
{
    uint8_t lsb;
    uint8_t msb;

    if (!ow_reset())
    {
        return 0;
    }

    ow_write_byte(0xCC);   /* Skip ROM  */
    ow_write_byte(0xBE);   /* Read Scratchpad */

    lsb = ow_read_byte();
    msb = ow_read_byte();

    ow_reset();   /* abort reading remaining scratchpad bytes */

    *raw_temp = (int16_t)((uint16_t)msb << 8 | lsb);
    return 1;
}

static void ds18b20_report(void)
{
    int16_t raw;
    int16_t whole;
    uint16_t frac;
    uint16_t frac2;

    if (!ds18b20_read_temperature(&raw))
    {
        uart_send_string("Temperature: Sensor Error\r\n");
        return;
    }

    /*
     * DS18B20 raw value is in 1/16 °C units (12-bit default resolution).
     * Example: raw = 0x0191 = 401 → 401/16 = 25.0625 °C
     *          raw = 0xFF5E = -162 → -162/16 = -10.125 °C
     */
    whole = raw / 16;
    frac  = ((uint16_t)(raw >= 0 ? raw : -raw) % 16) * 625;  /* 0–9375 (×0.0001 °C) */
    frac2 = frac / 100;  /* 2 decimal places: 0–93 */

    uart_send_string("Temperature: ");

    if (raw < 0)
    {
        uart_send_char('-');

        if (whole == 0)
        {
            uart_send_char('0');
        }
        else
        {
            uart_send_uint((uint32_t)(-whole));
        }
    }
    else
    {
        uart_send_uint((uint32_t)whole);
    }

    uart_send_char('.');
    if (frac2 < 10)
    {
        uart_send_char('0');
    }
    uart_send_uint((uint32_t)frac2);
    uart_send_string(" C\r\n");

    /* Send warning to mobile via Bluetooth every time temperature exceeds threshold */
    if (raw > (int16_t)(TEMP_WARNING_THRESHOLD_C * 16))
    {
        uart_send_string("Excessive heat detected\r\n");
    }
}

/* ================================================================
 *                        TWI / I2C DRIVER
 * ================================================================ */

#define TWI_TIMEOUT_COUNT 2000U

static void twi_init(void)
{
    /* PC0 = SCL, PC1 = SDA on ATmega32.
     * Configure as inputs with internal pull-up enabled */
    DDRC &= (uint8_t)~((1 << PC0) | (1 << PC1));
    PORTC |= (uint8_t)((1 << PC0) | (1 << PC1));

    /* Set 50 kHz SCL clock @ F_CPU = 1 MHz
     * SCL = F_CPU / (16 + 2 * TWBR * 4^TWPS)
     * With TWBR = 2, TWPS = 0: SCL = 1,000,000 / (16 + 4) = 50,000 Hz */
    TWSR = 0;           /* Prescaler = 1 */
    TWBR = 2;           /* Bit rate factor */
    TWCR = (1 << TWEN); /* Enable TWI */
}

static uint8_t twi_start(void)
{
    uint16_t timeout = TWI_TIMEOUT_COUNT;
    TWCR = (1 << TWINT) | (1 << TWSTA) | (1 << TWEN);
    while (!(TWCR & (1 << TWINT)))
    {
        if (--timeout == 0) return 0;
    }
    uint8_t status = TWSR & 0xF8;
    return (status == 0x08 || status == 0x10); /* START or REPEATED START */
}

static void twi_stop(void)
{
    uint16_t timeout = TWI_TIMEOUT_COUNT;
    TWCR = (1 << TWINT) | (1 << TWSTO) | (1 << TWEN);
    while (TWCR & (1 << TWSTO))
    {
        if (--timeout == 0) break;
    }
}

static uint8_t twi_write(uint8_t data)
{
    uint16_t timeout = TWI_TIMEOUT_COUNT;
    TWDR = data;
    TWCR = (1 << TWINT) | (1 << TWEN);
    while (!(TWCR & (1 << TWINT)))
    {
        if (--timeout == 0) return 0;
    }
    uint8_t status = TWSR & 0xF8;
    /* Return 1 if ACK received (0x18 = SLA+W ACK, 0x28 = Data ACK, 0x40 = SLA+R ACK) */
    return (status == 0x18 || status == 0x28 || status == 0x40);
}

static uint8_t twi_read_ack(uint8_t *data)
{
    uint16_t timeout = TWI_TIMEOUT_COUNT;
    TWCR = (1 << TWINT) | (1 << TWEN) | (1 << TWEA);
    while (!(TWCR & (1 << TWINT)))
    {
        if (--timeout == 0) return 0;
    }
    *data = TWDR;
    return 1;
}

static uint8_t twi_read_nack(uint8_t *data)
{
    uint16_t timeout = TWI_TIMEOUT_COUNT;
    TWCR = (1 << TWINT) | (1 << TWEN);
    while (!(TWCR & (1 << TWINT)))
    {
        if (--timeout == 0) return 0;
    }
    *data = TWDR;
    return 1;
}

/* ================================================================
 *            SOFTWARE I2C MASTER DRIVER (Bus 2: PC2/PC3)
 * ================================================================ */

/*
 * Bit-banged I2C Master on PC2 (SCL, pin 24) and PC3 (SDA, pin 25).
 * Open-drain operation:
 *   - To drive LOW: configure pin as output and write LOW.
 *   - To release HIGH: configure pin as input with internal pull-up enabled.
 *   - Lines are NEVER driven push-pull HIGH.
 * Target clock speed: ~50 kHz at F_CPU = 1 MHz.
 */
#define SOFT_I2C_DDR            DDRC
#define SOFT_I2C_PORT           PORTC
#define SOFT_I2C_PIN            PINC
#define SOFT_I2C_SCL            PC2    /* ATmega32 physical pin 24 */
#define SOFT_I2C_SDA            PC3    /* ATmega32 physical pin 25 */
#define SOFT_I2C_HALF_DELAY_US  10     /* Half-period delay (~40 kHz @ 1 MHz) */
#define SOFT_I2C_TIMEOUT_CYCLES 500U   /* Clock stretching / bus timeout */

static inline void soft_i2c_scl_low(void)
{
    SOFT_I2C_PORT &= (uint8_t)~(1 << SOFT_I2C_SCL);
    SOFT_I2C_DDR  |= (uint8_t)(1 << SOFT_I2C_SCL);
}

static inline void soft_i2c_scl_high(void)
{
    SOFT_I2C_DDR  &= (uint8_t)~(1 << SOFT_I2C_SCL);
    SOFT_I2C_PORT |= (uint8_t)(1 << SOFT_I2C_SCL);
}

static inline void soft_i2c_sda_low(void)
{
    SOFT_I2C_PORT &= (uint8_t)~(1 << SOFT_I2C_SDA);
    SOFT_I2C_DDR  |= (uint8_t)(1 << SOFT_I2C_SDA);
}

static inline void soft_i2c_sda_high(void)
{
    SOFT_I2C_DDR  &= (uint8_t)~(1 << SOFT_I2C_SDA);
    SOFT_I2C_PORT |= (uint8_t)(1 << SOFT_I2C_SDA);
}

static uint8_t soft_i2c_wait_scl_high(void)
{
    soft_i2c_scl_high();
    uint16_t timeout = SOFT_I2C_TIMEOUT_CYCLES;
    while (!(SOFT_I2C_PIN & (1 << SOFT_I2C_SCL)))
    {
        _delay_us(1);
        if (--timeout == 0)
        {
            return 0; /* Clock stretch timeout / bus fault */
        }
    }
    return 1;
}

static void soft_i2c_stop(void);

static void soft_i2c_init(void)
{
    /* Disable JTAG to free PC2 (TCK), PC3 (TMS), PC4 (TDO), PC5 (TDI) for GPIO.
     * ATmega32 requires writing JTD bit to 1 twice within 4 CPU cycles. */
    uint8_t mcucsr_val = MCUCSR | (1 << JTD);
    MCUCSR = mcucsr_val;
    MCUCSR = mcucsr_val;

    /* Initialize both lines released HIGH (inputs with pull-up enabled) */
    soft_i2c_scl_high();
    soft_i2c_sda_high();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Bus recovery: if slave was left pulling SDA low, toggle SCL up to 9 times */
    for (uint8_t i = 0; i < 9; i++)
    {
        if (SOFT_I2C_PIN & (1 << SOFT_I2C_SDA))
        {
            break;
        }
        soft_i2c_scl_low();
        _delay_us(SOFT_I2C_HALF_DELAY_US);
        soft_i2c_scl_high();
        _delay_us(SOFT_I2C_HALF_DELAY_US);
    }
    soft_i2c_stop();
}

static uint8_t soft_i2c_start(void)
{
    /* Ensure SDA and SCL are released HIGH */
    soft_i2c_sda_high();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    if (!soft_i2c_wait_scl_high())
    {
        return 0;
    }
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Pull SDA LOW while SCL is HIGH (START condition) */
    soft_i2c_sda_low();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Pull SCL LOW to complete START condition and prepare for bit clocking */
    soft_i2c_scl_low();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    return 1;
}

static void soft_i2c_stop(void)
{
    /* Ensure SCL is LOW, then pull SDA LOW */
    soft_i2c_scl_low();
    soft_i2c_sda_low();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Release SCL HIGH */
    soft_i2c_wait_scl_high();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Release SDA HIGH while SCL is HIGH (STOP condition) */
    soft_i2c_sda_high();
    _delay_us(SOFT_I2C_HALF_DELAY_US);
}

static uint8_t soft_i2c_write(uint8_t data)
{
    uint8_t i;
    for (i = 0; i < 8; i++)
    {
        if (data & 0x80)
        {
            soft_i2c_sda_high();
        }
        else
        {
            soft_i2c_sda_low();
        }
        _delay_us(SOFT_I2C_HALF_DELAY_US);

        if (!soft_i2c_wait_scl_high())
        {
            soft_i2c_scl_low();
            return 0;
        }
        _delay_us(SOFT_I2C_HALF_DELAY_US);

        soft_i2c_scl_low();
        _delay_us(SOFT_I2C_HALF_DELAY_US);
        data <<= 1;
    }

    /* 9th clock pulse: read ACK from slave */
    soft_i2c_sda_high();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    if (!soft_i2c_wait_scl_high())
    {
        soft_i2c_scl_low();
        return 0;
    }
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* ACK is active LOW (slave drives SDA low) */
    uint8_t ack = !(SOFT_I2C_PIN & (1 << SOFT_I2C_SDA));

    soft_i2c_scl_low();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    return ack; /* 1 = ACK, 0 = NACK */
}

static uint8_t soft_i2c_read_byte(uint8_t ack, uint8_t *data)
{
    uint8_t i;
    uint8_t byte = 0;

    /* Release SDA to receive data from slave */
    soft_i2c_sda_high();

    for (i = 0; i < 8; i++)
    {
        _delay_us(SOFT_I2C_HALF_DELAY_US);

        if (!soft_i2c_wait_scl_high())
        {
            soft_i2c_scl_low();
            return 0;
        }
        _delay_us(SOFT_I2C_HALF_DELAY_US);

        byte = (uint8_t)((byte << 1) | ((SOFT_I2C_PIN & (1 << SOFT_I2C_SDA)) ? 1 : 0));

        soft_i2c_scl_low();
        _delay_us(SOFT_I2C_HALF_DELAY_US);
    }

    /* Drive ACK (SDA=0) or NACK (SDA=1) */
    if (ack)
    {
        soft_i2c_sda_low();
    }
    else
    {
        soft_i2c_sda_high();
    }
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    if (!soft_i2c_wait_scl_high())
    {
        soft_i2c_scl_low();
        return 0;
    }
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    soft_i2c_scl_low();
    _delay_us(SOFT_I2C_HALF_DELAY_US);

    /* Release SDA after acknowledging */
    soft_i2c_sda_high();

    *data = byte;
    return 1;
}

static uint8_t soft_i2c_read_ack(uint8_t *data)
{
    return soft_i2c_read_byte(1, data);
}

static uint8_t soft_i2c_read_nack(uint8_t *data)
{
    return soft_i2c_read_byte(0, data);
}

/* ================================================================
 *                     DUAL INA219 DRIVER
 * ================================================================ */

#define INA219_REG_CONFIG       0x00
#define INA219_REG_SHUNTVOLTAGE 0x01
#define INA219_REG_BUSVOLTAGE   0x02
#define INA219_REG_POWER        0x03
#define INA219_REG_CURRENT      0x04
#define INA219_REG_CALIBRATION  0x05

typedef enum {
    INA219_BUS_HARDWARE = 0,  /* Bus 1: Hardware TWI (PC0 SCL, PC1 SDA) -> Solar Panel */
    INA219_BUS_SOFTWARE = 1   /* Bus 2: Software I2C (PC2 SCL, PC3 SDA) -> Battery / Load */
} ina219_bus_t;

static uint8_t ina219_write_reg(ina219_bus_t bus, uint8_t reg, uint16_t value)
{
    if (bus == INA219_BUS_HARDWARE)
    {
        if (!twi_start()) { twi_stop(); return 0; }
        if (!twi_write(INA219_I2C_ADDR_W)) { twi_stop(); return 0; }
        if (!twi_write(reg)) { twi_stop(); return 0; }
        if (!twi_write((uint8_t)(value >> 8))) { twi_stop(); return 0; }
        if (!twi_write((uint8_t)(value & 0xFF))) { twi_stop(); return 0; }
        twi_stop();
        return 1;
    }
    else
    {
        if (!soft_i2c_start()) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write(INA219_I2C_ADDR_W)) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write(reg)) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write((uint8_t)(value >> 8))) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write((uint8_t)(value & 0xFF))) { soft_i2c_stop(); return 0; }
        soft_i2c_stop();
        return 1;
    }
}

static uint8_t ina219_read_reg(ina219_bus_t bus, uint8_t reg, int16_t *value)
{
    uint8_t msb = 0, lsb = 0;
    if (bus == INA219_BUS_HARDWARE)
    {
        if (!twi_start()) { twi_stop(); return 0; }
        if (!twi_write(INA219_I2C_ADDR_W)) { twi_stop(); return 0; }
        if (!twi_write(reg)) { twi_stop(); return 0; }

        if (!twi_start()) { twi_stop(); return 0; }
        if (!twi_write(INA219_I2C_ADDR_R)) { twi_stop(); return 0; }
        if (!twi_read_ack(&msb)) { twi_stop(); return 0; }
        if (!twi_read_nack(&lsb)) { twi_stop(); return 0; }
        twi_stop();
    }
    else
    {
        if (!soft_i2c_start()) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write(INA219_I2C_ADDR_W)) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write(reg)) { soft_i2c_stop(); return 0; }
        soft_i2c_stop();
        _delay_us(10);

        if (!soft_i2c_start()) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_write(INA219_I2C_ADDR_R)) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_read_ack(&msb)) { soft_i2c_stop(); return 0; }
        if (!soft_i2c_read_nack(&lsb)) { soft_i2c_stop(); return 0; }
        soft_i2c_stop();
    }

    *value = (int16_t)(((uint16_t)msb << 8) | lsb);
    return 1;
}

static uint8_t ina219_init_device(ina219_bus_t bus)
{
    if (bus == INA219_BUS_HARDWARE)
    {
        twi_init();
    }
    else
    {
        soft_i2c_init();
    }

    /* Config register: 32V Bus FSR, 320mV Shunt FSR, 12-bit ADC, continuous (0x399F) */
    if (!ina219_write_reg(bus, INA219_REG_CONFIG, 0x399F))
    {
        return 0; /* Sensor communication failed */
    }

    /* Calibration register for 0.1 ohm shunt (LSB = 0.1 mA) */
    return ina219_write_reg(bus, INA219_REG_CALIBRATION, 4096);
}

static uint8_t ina219_1_init(void)
{
    return ina219_init_device(INA219_BUS_HARDWARE);
}

static uint8_t ina219_2_init(void)
{
    return ina219_init_device(INA219_BUS_SOFTWARE);
}


static uint8_t ina219_get_readings_device(ina219_bus_t bus, int32_t *voltage_uv, int32_t *current_ua, int32_t *power_uw)
{
    int16_t raw_bus = 0;
    int16_t raw_shunt = 0;

    if (!ina219_read_reg(bus, INA219_REG_BUSVOLTAGE, &raw_bus))
    {
        return 0;
    }

    if (!ina219_read_reg(bus, INA219_REG_SHUNTVOLTAGE, &raw_shunt))
    {
        return 0;
    }

    /* Bus voltage register: bits 15:3 contain voltage, 4 mV (= 4000 uV) per count. */
    int32_t v_uv = ((int32_t)(raw_bus >> 3)) * 4000L;
    if (v_uv < 0) v_uv = 0;

    /* Shunt voltage register: 10 uV per count.
     * With standard 0.1 ohm shunt (R100):
     * Current (uA) = (raw_shunt * 10 uV) / 0.1 ohm = raw_shunt * 100 */
    int32_t c_ua = ((int32_t)raw_shunt) * 100L;
    if (c_ua < 0) c_ua = 0;

    /* Power in microwatts: P(uW) = V(uV) * I(uA) / 1,000,000
     * Since v_uv is always a multiple of 4000 and c_ua a multiple of 100,
     * splitting as (v_uv/1000) * (c_ua/100) / 10 is lossless and avoids
     * both int32 overflow and early truncation to zero. */
    int32_t p_uw = ((v_uv / 1000L) * (c_ua / 100L)) / 10L;

    *voltage_uv = v_uv;
    *current_ua = c_ua;
    *power_uw = p_uw;
    return 1;
}

static uint8_t ina219_1_get_readings(int32_t *voltage_uv, int32_t *current_ua, int32_t *power_uw)
{
    return ina219_get_readings_device(INA219_BUS_HARDWARE, voltage_uv, current_ua, power_uw);
}

static uint8_t ina219_2_get_readings(int32_t *voltage_uv, int32_t *current_ua, int32_t *power_uw)
{
    return ina219_get_readings_device(INA219_BUS_SOFTWARE, voltage_uv, current_ua, power_uw);
}


static void print_ina219_data(const char *prefix, int32_t v_uv, int32_t c_ua, int32_t p_uw)
{
    /* Voltage: X.XXXXXX V (from uV, 6 decimal places) */
    uint32_t v_abs = (uint32_t)v_uv;
    uint32_t v_int = v_abs / 1000000UL;
    uint32_t v_frac = v_abs % 1000000UL;

    uart_send_string(prefix);
    uart_send_string(" Voltage: ");
    uart_send_uint(v_int);
    uart_send_char('.');
    if (v_frac < 100000UL) uart_send_char('0');
    if (v_frac < 10000UL)  uart_send_char('0');
    if (v_frac < 1000UL)   uart_send_char('0');
    if (v_frac < 100UL)    uart_send_char('0');
    if (v_frac < 10UL)     uart_send_char('0');
    uart_send_uint(v_frac);
    uart_send_string(" V\r\n");

    /* Current: X.XXX mA (from uA, 3 decimal places) */
    uint32_t c_abs = (uint32_t)c_ua;
    uint32_t c_int = c_abs / 1000UL;
    uint32_t c_frac = c_abs % 1000UL;

    uart_send_string(prefix);
    uart_send_string(" Current: ");
    uart_send_uint(c_int);
    uart_send_char('.');
    if (c_frac < 100UL) uart_send_char('0');
    if (c_frac < 10UL)  uart_send_char('0');
    uart_send_uint(c_frac);
    uart_send_string(" mA\r\n");

    /* Power: X.XXX mW (from uW, 3 decimal places) */
    uint32_t p_abs = (uint32_t)p_uw;
    uint32_t p_int = p_abs / 1000UL;
    uint32_t p_frac = p_abs % 1000UL;

    uart_send_string(prefix);
    uart_send_string(" Power: ");
    uart_send_uint(p_int);
    uart_send_char('.');
    if (p_frac < 100UL) uart_send_char('0');
    if (p_frac < 10UL)  uart_send_char('0');
    uart_send_uint(p_frac);
    uart_send_string(" mW\r\n");
}

static void ina219_report(void)
{
    int32_t v_uv = 0;
    int32_t c_ua = 0;
    int32_t p_uw = 0;

    /* INA219 #1: Solar Panel input (Hardware TWI, PC0/PC1) */
    if (ina219_1_get_readings(&v_uv, &c_ua, &p_uw))
    {
        print_ina219_data("Solar", v_uv, c_ua, p_uw);
    }
    else
    {
        uart_send_string("INA219 #1: Communication Error\r\n");
    }

    /* INA219 #2: Battery / Load output (Software I2C, PC2/PC3) */
    if (ina219_2_get_readings(&v_uv, &c_ua, &p_uw))
    {
        print_ina219_data("Battery", v_uv, c_ua, p_uw);
    }
    else
    {
        uart_send_string("INA219 #2: Communication Error\r\n");
    }
}

/* ================================================================
 *                               MAIN
 * ================================================================ */

int main(void)
{
    MCUCSR |= (1 << JTD);
    MCUCSR |= (1 << JTD);
    uint16_t ldr1, ldr2, ldr3, ldr4;
    uint16_t left, right, top, bottom;
    uint16_t average_light;

    int16_t measured_horizontal_error;
    int16_t measured_vertical_error;
    int16_t horizontal_error;
    int16_t vertical_error;

    uint8_t az_step;
    uint8_t el_step;

    char current_mode = 'A'; /* 'A' = Auto, 'M' = Manual */
    uint8_t ina219_loop_count = 0;
    uint8_t last_reported_rain = 0xFF; /* Force a startup report. */
    char last_reported_mode = 0;
    uint8_t ds18b20_ready = 0;  /* 1 = conversion started, can read next cycle */

    /* Disable JTAG interface to release Port C pins (PC2, PC3, PC4, PC5) as GPIO.
     * ATmega32 requires writing JTD bit to 1 twice within 4 CPU cycles. */
    uint8_t mcucsr_val = MCUCSR | (1 << JTD);
    MCUCSR = mcucsr_val;
    MCUCSR = mcucsr_val;

    adc_init();
    servo_init();
    uart_init();
    rain_sensor_init();
    _delay_ms(20);
    ina219_1_init();
    ina219_2_init();

    /* Give both axes time to reach the known center position. */
    _delay_ms(800);

    /*
     * Learn the sensor pattern corresponding to MAXIMUM PANEL illumination.
     * Keep the light aimed at the SOLAR PANEL center during this period.
     */
    calibrate_panel_alignment();

    /* Start cleanly after calibration. */
    azimuth_state = 0;
    elevation_state = 0;

    uart_send_string("Solar Tracker Online. Dual INA219 Monitoring Started.\r\n");

    while (1)
    {
        char cmd = 0;
        char temp_cmd;
        uint8_t rain_reported = 0;

        /* Drain UART buffer and process mode changes immediately */
        while ((temp_cmd = uart_receive_non_blocking()) != 0)
        {
            if (temp_cmd == 'A' || temp_cmd == 'a')
            {
                current_mode = 'A';
                azimuth_state = 0;
                elevation_state = 0;
            }
            else if (temp_cmd == 'M' || temp_cmd == 'm')
            {
                current_mode = 'M';
                azimuth_state = 0;
                elevation_state = 0;
            }
            else if (temp_cmd != '\r' && temp_cmd != '\n' && temp_cmd != ' ')
            {
                cmd = temp_cmd; /* Store the last movement command */
            }
        }

        /* Use one rain sample for telemetry and protection in this iteration. */
        uint8_t rain_now = is_rain_detected();
        if (rain_now && current_mode == 'A')
        {
            azimuth_state = 0;
            elevation_state = 0;
        }

        /* Announce transitions promptly, before slower sensor reporting.
         * Mode changes during rain must update the protection message too. */
        if (rain_now != last_reported_rain || current_mode != last_reported_mode)
        {
            report_rain_status(rain_now, current_mode);
            last_reported_rain = rain_now;
            last_reported_mode = current_mode;
            rain_reported = 1;
        }

        /* Periodic ~1-second Dual INA219 + Temperature Report (non-blocking) */
        if (++ina219_loop_count >= INA219_REPORT_LOOPS)
        {
            ina219_loop_count = 0;
            /* Heartbeat keeps late/reconnecting phones informed even if
             * the weather has not changed. No duplicate in a transition loop. */
            if (!rain_reported)
                report_rain_status(rain_now, current_mode);
            ina219_report();

            /* DS18B20 two-phase: read PREVIOUS conversion, then start a new one.
             * Phase 2 (read) needs ≥750 ms after Phase 1 (convert);
             * our ~1 s report cycle satisfies this easily. */
            if (ds18b20_ready)
            {
                ds18b20_report();
            }
            ds18b20_start_conversion();
            ds18b20_ready = 1;

            uart_send_string("------------------------\r\n");
        }

        if (current_mode == 'M')
        {
            if (cmd == 'L' || cmd == 'l')
            {
                move_azimuth(+1, 15);
            }
            else if (cmd == 'R' || cmd == 'r')
            {
                move_azimuth(-1, 15);
            }
            else if (cmd == 'U' || cmd == 'u')
            {
                move_elevation(+1, 15);
            }
            else if (cmd == 'D' || cmd == 'd')
            {
                move_elevation(-1, 15);
            }
            
            _delay_ms(CONTROL_DELAY_MS);
            continue;
        }

        /*
         * RAIN PROTECTION:
         * When rain is detected, tilt the panel vertically so rain runs off
         * with minimum impact. The panel will not respond to light at all
         * until the rain is completely gone.
         */
        if (rain_now)
        {
            azimuth_state = 0;
            elevation_state = 0;

            /* Smoothly glide elevation to the vertical stow position */
            set_elevation_target(EL_RAIN_VERTICAL_CMD);

#if AZ_RAIN_CENTER_ENABLED
            set_azimuth_target(AZ_START_CMD);
#endif

            _delay_ms(CONTROL_DELAY_MS);
            continue;
        }

        read_directional_values(
            &ldr1, &ldr2, &ldr3, &ldr4,
            &left, &right, &top, &bottom
        );

        average_light = (uint16_t)(
            ((uint32_t)ldr1 + ldr2 + ldr3 + ldr4) / 4UL
        );

        if (average_light < MIN_TRACKING_LIGHT_ADC)
        {
            /* Stay where we are instead of hunting in darkness. */
            azimuth_state = 0;
            elevation_state = 0;
            _delay_ms(CONTROL_DELAY_MS);
            continue;
        }

        measured_horizontal_error = relative_error(left, right);
        measured_vertical_error   = relative_error(top, bottom);

        /*
         * We do NOT demand LDR equality. We demand the calibrated LDR
         * pattern that corresponded to the solar panel itself being
         * correctly aimed.
         */
        horizontal_error =
            measured_horizontal_error - horizontal_target_error;

        vertical_error =
            measured_vertical_error - vertical_target_error;

        azimuth_state = update_motion_state(
            horizontal_error,
            azimuth_state
        );

        elevation_state = update_motion_state(
            vertical_error,
            elevation_state
        );

        az_step = adaptive_step(horizontal_error);
        el_step = adaptive_step(vertical_error);

        /* Both axes are allowed to correct in the same control cycle. */
        move_azimuth(azimuth_state, az_step);
        move_elevation(elevation_state, el_step);

        _delay_ms(CONTROL_DELAY_MS);
    }

    return 0;
}

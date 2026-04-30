// motor_controller.h

// --- Motor Constants ---
const float Kt = 0.085f;       // N·m/A
const float Ke = 0.0859f;      // V·s/rad
const float R  = 0.4f;         // Ohms
const float L  = 0.0003f;      // H (estimated)

// --- Controller Gains ---
const float Kp  = 0.5f;        // A/A
const float Ki  = 3.0f;        // A/(A·s)

// --- Limits ---
const float V_SUPPLY    = 36.0f;                // V
const float I_MAX       =  28.0f;               // A
const float I_MIN       = -28.0f;               // A
const float I_CMD_MAX   =  V_SUPPLY / R;        // hard electrical limit
const float I_CMD_MIN   = -V_SUPPLY / R;

// --- Controller State ---
float integrator = 0.0f;
float t_prev     = -1.0f;      // negative flags "not yet initialized"

// --- Reset (call on mode switch or startup) ---
void resetController() {
    integrator = 0.0f;
    t_prev     = -1.0f;
}

// --- Main Control Function ---
// Returns current command in amps (negative = active braking)
float currentController(float i_measured, float omega, float t, float i_target) {

    // First call init
    if (t_prev < 0.0f) {
        t_prev = t;
        return i_target;    // pass through on first call
    }

    float dt = t - t_prev;
    t_prev = t;

    if (dt <= 0.0f) return i_target;   // guard against bad timing

    // Error
    float e = i_target - i_measured;

    // Feedforward: cancel back-EMF effect on current
    float i_ff = i_target - (Ke * omega) / R;

    // PI terms
    float i_cmd_unsat = i_ff + Kp * e + integrator;

    // Deal with saturated output
    float i_cmd = i_cmd_unsat;
    if (i_cmd >  I_MAX) i_cmd =  I_MAX;
    if (i_cmd <  I_MIN) i_cmd =  I_MIN;

    // Anti-windup back-calculation
    integrator += Ki * e * dt + (1.0f / Kp) * (i_cmd - i_cmd_unsat) * dt;

    return i_cmd;
}
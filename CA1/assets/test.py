import os
import struct
import numpy as np
import matplotlib.pyplot as plt


# ============================================================
# Configuration
# ============================================================

DATA_DIR = "."          # folder containing the FP16 .mem files
                        # (fc1_weights.mem, fc1_bias.mem, fc2_weights.mem,
                        #  fc2_bias.mem, test_image.mem)

FP32_DIR = None         # optional: folder with the original FP32 .mem files
                        # for comparison, e.g. "data_fp32" (None = skip)

INPUT_SIZE = 784
HIDDEN_SIZE = 8
OUTPUT_SIZE = 10


# ============================================================
# IEEE-754 FP16 HEX (4 digits) -> Python float
# ============================================================

def hex_to_float16(hex_string):
    """
    Convert a 4-character IEEE-754 half-precision hexadecimal
    value into a numpy float16 value.
    """
    integer = int(hex_string, 16)

    return np.float16(
        struct.unpack(
            ">e",
            struct.pack(">H", integer)
        )[0]
    )


def hex_to_float32(hex_string):
    integer = int(hex_string, 16)

    return struct.unpack(
        ">f",
        struct.pack(">I", integer)
    )[0]


# ============================================================
# Read .mem file
# ============================================================

def read_mem(folder, filename, dtype=np.float16):

    convert = hex_to_float16 if dtype == np.float16 else hex_to_float32

    with open(os.path.join(folder, filename), "r") as f:

        values = []

        for line in f:
            line = line.strip()

            if line:
                values.append(convert(line))

    return np.array(values, dtype=dtype)


# ============================================================
# Load everything from the .mem files
# ============================================================

print("Loading FP16 model from:", os.path.abspath(DATA_DIR))

fc1_weights = read_mem(DATA_DIR, "fc1_weights.mem").reshape(HIDDEN_SIZE, INPUT_SIZE)
fc1_bias    = read_mem(DATA_DIR, "fc1_bias.mem")
fc2_weights = read_mem(DATA_DIR, "fc2_weights.mem").reshape(OUTPUT_SIZE, HIDDEN_SIZE)
fc2_bias    = read_mem(DATA_DIR, "fc2_bias.mem")
test_image  = read_mem(DATA_DIR, "test_image.mem")


# ============================================================
# Check dimensions
# ============================================================

print("\nModel dimensions:")
print("FC1 weights:", fc1_weights.shape, fc1_weights.dtype)
print("FC1 bias   :", fc1_bias.shape)
print("FC2 weights:", fc2_weights.shape)
print("FC2 bias   :", fc2_bias.shape)
print("Test image :", test_image.shape)

assert fc1_weights.shape == (HIDDEN_SIZE, INPUT_SIZE)
assert fc1_bias.shape == (HIDDEN_SIZE,)
assert fc2_weights.shape == (OUTPUT_SIZE, HIDDEN_SIZE)
assert fc2_bias.shape == (OUTPUT_SIZE,)
assert test_image.shape == (INPUT_SIZE,)


# ============================================================
# Display the MNIST image
# ============================================================

image = test_image.astype(np.float32).reshape(28, 28)

plt.figure(figsize=(5, 5))
plt.imshow(image, cmap="gray", vmin=0.0, vmax=1.0)
plt.title("MNIST Test Image (FP16)")
plt.colorbar()
plt.show()


# ============================================================
# Golden Model
#
# Two arithmetic modes:
#
#   "fp16"     : every multiply and every add is rounded to FP16
#                (a plain FP16 multiplier + FP16 adder, MAC loop
#                 in the same order as the .mem files)
#
#   "fp16_acc32": FP16 inputs/weights, products and the running
#                 sum are kept in FP32, the result is rounded to
#                 FP16 once at the end of each neuron
#                 (FP16 storage with a wide accumulator)
#
# The loop order matches the file layout:
#   layer 1: neuron (outer) -> pixel (inner), W1[n*784 + p]
#   layer 2: digit  (outer) -> hidden (inner), W2[d*8 + h]
# ============================================================

def mac(weights_row, x, bias, mode):

    if mode == "fp16":

        acc = np.float16(bias)

        for w, v in zip(weights_row, x):
            product = np.float16(w * v)          # round after multiply
            acc = np.float16(acc + product)      # round after add

        return acc

    elif mode == "fp16_acc32":

        acc = np.float32(bias)

        for w, v in zip(weights_row, x):
            acc = np.float32(acc + np.float32(w) * np.float32(v))

        return np.float16(acc)

    raise ValueError(mode)


def golden_model(x, mode="fp16"):

    # --------------------------------------------------------
    # Layer 1:  fc1[n] = sum_p W1[n][p] * x[p] + b1[n]
    # --------------------------------------------------------

    fc1 = np.array(
        [mac(fc1_weights[n], x, fc1_bias[n], mode)
         for n in range(HIDDEN_SIZE)],
        dtype=np.float16
    )

    # --------------------------------------------------------
    # ReLU
    # --------------------------------------------------------

    hidden = np.maximum(fc1, np.float16(0.0))

    # --------------------------------------------------------
    # Layer 2:  out[d] = sum_h W2[d][h] * hidden[h] + b2[d]
    # --------------------------------------------------------

    output = np.array(
        [mac(fc2_weights[d], hidden, fc2_bias[d], mode)
         for d in range(OUTPUT_SIZE)],
        dtype=np.float16
    )

    # --------------------------------------------------------
    # Argmax
    # --------------------------------------------------------

    prediction = int(np.argmax(output))

    return fc1, hidden, output, prediction


# ============================================================
# Run Golden Model (pure FP16 arithmetic)
# ============================================================

MODE = "fp16"        # change to "fp16_acc32" for the wide-accumulator version

fc1_output, hidden_output, output, prediction = golden_model(test_image, MODE)


# ============================================================
# Display results
# ============================================================

def hex16(v):
    return f"{int(np.float16(v).view(np.uint16)):04X}"


print("\n========================================")
print(f"   GOLDEN MODEL RESULTS  (FP16, mode={MODE})")
print("========================================")

print("\nFC1 output:")
for i, value in enumerate(fc1_output):
    print(f"  neuron {i:2d}: {float(value):.8f}   (0x{hex16(value)})")

print("\nReLU / Hidden output:")
for i, value in enumerate(hidden_output):
    print(f"  neuron {i:2d}: {float(value):.8f}   (0x{hex16(value)})")

print("\nFinal output logits:")
for i, value in enumerate(output):
    print(f"  digit {i}: {float(value):.8f}   (0x{hex16(value)})")

print("\n========================================")
print(f"PREDICTED DIGIT: {prediction}")
print("========================================")


# ============================================================
# Show output probabilities
# ============================================================

# Softmax is NOT used by the RTL classifier.
# It is only useful for visualization (computed in FP32).

logits = output.astype(np.float32)

exp_output = np.exp(logits - np.max(logits))
probabilities = exp_output / np.sum(exp_output)

print("\nApproximate probabilities:")

for digit, probability in enumerate(probabilities):
    print(f"  {digit}: {probability * 100:.2f}%")


# ============================================================
# Plot prediction probabilities
# ============================================================

plt.figure(figsize=(8, 4))
plt.bar(range(10), probabilities)
plt.xticks(range(10))
plt.xlabel("Digit")
plt.ylabel("Probability")
plt.title(f"Golden Model (FP16) Prediction = {prediction}")
plt.show()

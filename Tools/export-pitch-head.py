"""Exports the pitch head for the Neural Engine.

The first attempt used `linear` on a rank-2 input, which is the obvious way to
write two matrix multiplies and lands entirely on the CPU: every operation came
back `MLCPUComputeDevice`. The Neural Engine's primitive is a convolution over a
four-dimensional tensor, and a fully connected layer reaches it only when it is
written as a 1×1 convolution over (1, channels, 1, 1). That is not an
optimisation — it is the difference between using the hardware and saying you do.
"""
import numpy as np, coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

d = np.load("/tmp/pitchhead.npz")
W1, b1, W2, b2 = d["W1"], d["b1"], d["W2"], d["b2"]
WIDTH, HIDDEN = int(d["width"]), W1.shape[1]

# Core ML wants conv weights as (out, in, kh, kw).
K1 = W1.T.reshape(HIDDEN, WIDTH, 1, 1).astype(np.float32)
K2 = W2.T.reshape(WIDTH, HIDDEN, 1, 1).astype(np.float32)

@mb.program(input_specs=[mb.TensorSpec(shape=(1, WIDTH, 1, 1), dtype=types.fp32)])
def head(curve):
    h = mb.conv(x=curve, weight=K1, bias=b1.astype(np.float32))
    h = mb.relu(x=h)
    z = mb.conv(x=h, weight=K2, bias=b2.astype(np.float32))
    # Over the channel axis, which is where the lags live in this layout.
    return mb.softmax(x=z, axis=1, name="lagProbabilities")

model = ct.convert(
    head,
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    compute_units=ct.ComputeUnit.ALL,
    minimum_deployment_target=ct.target.macOS14,
)
model.short_description = (
    "Chooses which periodicity in an autocorrelation curve belongs to the singer."
)
model.user_defined_metadata["minimumLag"] = str(int(d["minimumLag"]))
model.user_defined_metadata["sampleRate"] = str(float(d["sampleRate"]))
model.save("/tmp/PitchHead.mlpackage")
print("saved")

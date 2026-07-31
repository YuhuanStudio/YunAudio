"""Trains the pitch-decision head and exports it for the Neural Engine.

What is being learned is deliberately narrow. The autocorrelation front end
already measures periodicity to 0.0 cents on a clean vowel — better than a small
network would — and it fails at one thing: *choosing* which of several honest
periodicities belongs to the singer when a backing track sits at the same level.
So the front end stays, and the network reads its curve and answers the choice.

The output is a distribution over lags rather than a number. A regression head
would average two candidates and land between them, which is the one answer that
is certainly wrong; a distribution can be bimodal and say so, and the argmax with
a parabolic refinement is the same interpolation the rule already uses.
"""
import json, numpy as np

meta = json.load(open("/tmp/pitchdata-meta.json"))
W, ROWS = meta["width"], meta["rows"]
LO, RATE = meta["minimumLag"], meta["sampleRate"]

X = np.fromfile("/tmp/pitchdata-x.f32", dtype=np.float32).reshape(ROWS, W)
f0 = np.fromfile("/tmp/pitchdata-y.f32", dtype=np.float32)

# Labels: the lag bin the true pitch falls in, smoothed over its neighbours.
# A hard one-hot punishes a one-sample miss as hard as an octave, and the target
# is genuinely continuous — the true period is rarely a whole number of samples.
lag = RATE / f0
idx = np.clip(np.round(lag - LO).astype(int), 0, W - 1)
Y = np.zeros((ROWS, W), dtype=np.float32)
rows = np.arange(ROWS)
for off, weight in ((-2, .1), (-1, .6), (0, 1.), (1, .6), (2, .1)):
    j = np.clip(idx + off, 0, W - 1)
    Y[rows, j] = np.maximum(Y[rows, j], weight)
Y /= Y.sum(1, keepdims=True)

split = int(ROWS * .9)
Xtr, Ytr, Xte, Yte, lagte = X[:split], Y[:split], X[split:], Y[split:], lag[split:]

rng = np.random.default_rng(0)
H = 192
def init(a, b): return (rng.standard_normal((a, b)) * np.sqrt(2 / a)).astype(np.float32)
W1, b1 = init(W, H), np.zeros(H, np.float32)
W2, b2 = init(H, W), np.zeros(W, np.float32)

def forward(x):
    h = np.maximum(x @ W1 + b1, 0)
    z = h @ W2 + b2
    z -= z.max(1, keepdims=True)
    e = np.exp(z)
    return h, e / e.sum(1, keepdims=True)

def cents_error(x, truelag):
    _, p = forward(x)
    k = p.argmax(1)
    # Parabolic refinement, the same one the rule uses.
    kl, kr = np.clip(k - 1, 0, W - 1), np.clip(k + 1, 0, W - 1)
    a, c = p[np.arange(len(k)), kl], p[np.arange(len(k)), kr]
    b = p[np.arange(len(k)), k]
    den = a - 2 * b + c
    off = np.where(den != 0, .5 * (a - c) / np.where(den == 0, 1, den), 0)
    est = k + LO + np.clip(off, -1, 1)
    return np.abs(1200 * np.log2(est / truelag))

lr, batch = 0.05, 256
for epoch in range(24):
    order = rng.permutation(split)
    for s in range(0, split, batch):
        b_ = order[s:s + batch]
        x, y = Xtr[b_], Ytr[b_]
        h, p = forward(x)
        g = (p - y) / len(b_)
        gW2, gb2 = h.T @ g, g.sum(0)
        gh = (g @ W2.T) * (h > 0)
        gW1, gb1 = x.T @ gh, gh.sum(0)
        W1 -= lr * gW1; b1 -= lr * gb1; W2 -= lr * gW2; b2 -= lr * gb2
    if epoch % 4 == 3 or epoch == 23:
        e = cents_error(Xte, lagte)
        print(f"epoch {epoch+1:2d}  median {np.median(e):6.1f}¢  "
              f"within 50¢ {100*(e<50).mean():5.1f}%  within 100¢ {100*(e<100).mean():5.1f}%")

np.savez("/tmp/pitchhead.npz", W1=W1, b1=b1, W2=W2, b2=b2,
         minimumLag=LO, width=W, sampleRate=RATE)
print("saved", W1.size + W2.size + b1.size + b2.size, "parameters")

/// Returns an audio sample that is safe to admit into stateful realtime DSP.
///
/// One NaN from a driver or plugin otherwise survives indefinitely in a
/// biquad's history and poisons every later block. Subnormal floats are more
/// than 700 dB below full scale, so they are inaudible, but repeatedly carrying
/// them through a long filter cascade can take a slow floating-point path.
/// Testing the IEEE-754 exponent handles both cases without calling the Swift
/// runtime or changing any normal audio sample.
@inline(__always)
func sanitisedAudioSample(_ sample: Float) -> Float {
    let exponent = sample.bitPattern & 0x7F80_0000
    return exponent == 0 || exponent == 0x7F80_0000 ? 0 : sample
}

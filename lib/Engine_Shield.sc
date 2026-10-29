// shield: a test tone on the left or the right output only, to find out which
// output jack is which

Engine_Shield : CroneEngine {

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var server = context.server;

    // a soft sine with a short fade in and out, on one channel (pan -1 left, 1 right)
    SynthDef(\shield_tone, { arg out, freq = 440, dur = 0.6, amp = 0.25, pan = -1;
      var env = EnvGen.ar(Env.linen(0.01, dur, 0.05), doneAction: 2);
      var sig = SinOsc.ar(freq) * env * amp;
      Out.ar(out, Pan2.ar(sig, pan));
    }).add;

    server.sync;

    // tone(pan, freq, dur): a test tone on the left (-1) or right (1) output
    this.addCommand("tone", "fff", { arg msg;
      Synth.new(\shield_tone, [\out, context.out_b.index, \pan, msg[1], \freq, msg[2], \dur, msg[3]],
        context.xg);
    });
  }

  free {}

}

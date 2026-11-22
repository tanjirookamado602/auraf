import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auraf/auraf_telemetry.dart';

/// Timing of one inference request, measured on the UI isolate.
class InferenceResult {
  const InferenceResult({
    required this.ttftMs,
    required this.totalLatencyMs,
    required this.outputTokens,
    required this.succeeded,
    this.failureReason,
  });

  final double ttftMs;
  final double totalLatencyMs;
  final int outputTokens;
  final bool succeeded;
  final String? failureReason;

  /// Protocol decode throughput: (N - 1) / (t_eos - t_first_token).
  double get tokensPerSec {
    final decodeMs = totalLatencyMs - ttftMs;
    if (!succeeded || outputTokens < 2 || decodeMs <= 0) return 0;
    return (outputTokens - 1) / (decodeMs / 1000.0);
  }
}

/// Placeholder engines for M2. Real cloud APIs and on-device runtimes are
/// selected in M3 and implement this same interface.
abstract interface class InferenceBackend {
  Future<InferenceResult> generate({
    required String prompt,
    required int contextTokens,
    required int outputTokens,
  });
}

/// Delay and loss characteristics of one emulated network condition
/// (measurement protocol §3 table).
class NetworkProfile {
  const NetworkProfile({
    required this.minRttMs,
    required this.maxRttMs,
    required this.lossRate,
    this.reachable = true,
  });

  factory NetworkProfile.of(NetworkCondition condition) => switch (condition) {
        NetworkCondition.stable =>
          const NetworkProfile(minRttMs: 20, maxRttMs: 50, lossRate: 0),
        NetworkCondition.highLatency =>
          const NetworkProfile(minRttMs: 200, maxRttMs: 500, lossRate: 0),
        NetworkCondition.intermittent =>
          const NetworkProfile(minRttMs: 100, maxRttMs: 800, lossRate: 0.10),
        NetworkCondition.offline => const NetworkProfile(
            minRttMs: 0,
            maxRttMs: 0,
            lossRate: 1,
            reachable: false,
          ),
      };

  final int minRttMs;
  final int maxRttMs;
  final double lossRate;
  final bool reachable;

  int sampleRtt(math.Random rng) =>
      minRttMs + rng.nextInt(math.max(1, maxRttMs - minRttMs + 1));

  /// Retransmission timeout added when a packet is lost (RFC 6298 floor).
  int lossPenaltyMs(math.Random rng) => math.max(200, 2 * sampleRtt(rng));
}

/// Emulated cloud LLM endpoint. Delays are real wall-clock waits, so the
/// harness measures them exactly as it will measure a real API in M3.
class SimulatedCloudBackend implements InferenceBackend {
  SimulatedCloudBackend({
    required this.network,
    required this.random,
    required this.offlineTimeoutMs,
    this.serverPrefillTokensPerSec = 20000,
    this.serverDecodeTokensPerSec = 120,
    this.streamChunkTokens = 8,
  });

  final NetworkProfile network;
  final math.Random random;
  final int offlineTimeoutMs;
  final double serverPrefillTokensPerSec;
  final double serverDecodeTokensPerSec;
  final int streamChunkTokens;

  Future<void> _wait(num ms) =>
      Future<void>.delayed(Duration(microseconds: (ms * 1000).round()));

  int _roundTrip() {
    var ms = network.sampleRtt(random);
    if (random.nextDouble() < network.lossRate) ms += network.lossPenaltyMs(random);
    return ms;
  }

  @override
  Future<InferenceResult> generate({
    required String prompt,
    required int contextTokens,
    required int outputTokens,
  }) async {
    final clock = Stopwatch()..start();
    if (!network.reachable) {
      await _wait(offlineTimeoutMs);
      final elapsed = clock.elapsedMicroseconds / 1000.0;
      return InferenceResult(
        ttftMs: elapsed,
        totalLatencyMs: elapsed,
        outputTokens: 0,
        succeeded: false,
        failureReason: 'cloud unreachable (timeout ${offlineTimeoutMs}ms)',
      );
    }

    // Connection setup + request upload, then server-side prefill.
    await _wait(_roundTrip() + _roundTrip());
    await _wait(contextTokens / serverPrefillTokensPerSec * 1000);
    await _wait(1000 / serverDecodeTokensPerSec);
    final ttft = clock.elapsedMicroseconds / 1000.0;

    // Remaining tokens stream back in chunks; each chunk may hit a loss stall.
    var produced = 1;
    while (produced < outputTokens) {
      final chunk = math.min(streamChunkTokens, outputTokens - produced);
      var ms = chunk / serverDecodeTokensPerSec * 1000;
      if (random.nextDouble() < network.lossRate) ms += network.lossPenaltyMs(random);
      await _wait(ms);
      produced += chunk;
    }
    return InferenceResult(
      ttftMs: ttft,
      totalLatencyMs: clock.elapsedMicroseconds / 1000.0,
      outputTokens: produced,
      succeeded: true,
    );
  }
}

/// Emulated on-device model. It runs real floating-point work on a background
/// isolate (prefill proportional to context, decode per token with an
/// attention term over the context), so the phone's CPU, battery and
/// temperature respond as they would to a small local model.
class SimulatedDeviceBackend implements InferenceBackend {
  SimulatedDeviceBackend({this.workScale = 1.0});

  final double workScale;

  @override
  Future<InferenceResult> generate({
    required String prompt,
    required int contextTokens,
    required int outputTokens,
  }) async {
    final port = ReceivePort();
    final clock = Stopwatch()..start();
    double? ttft;
    var tokens = 0;
    final done = Completer<void>();

    final sub = port.listen((Object? message) {
      if (message == 'first') {
        ttft = clock.elapsedMicroseconds / 1000.0;
      } else if (message is int) {
        tokens = message;
        if (!done.isCompleted) done.complete();
      } else if (message is List && !done.isCompleted) {
        done.completeError(StateError('device worker failed: $message'));
      }
    });

    final isolate = await Isolate.spawn<_DeviceJob>(
      _deviceWorker,
      _DeviceJob(port.sendPort, contextTokens, outputTokens, workScale),
      onError: port.sendPort,
    );
    try {
      await done.future;
    } finally {
      await sub.cancel();
      port.close();
      isolate.kill(priority: Isolate.immediate);
    }
    final total = clock.elapsedMicroseconds / 1000.0;
    return InferenceResult(
      ttftMs: ttft ?? total,
      totalLatencyMs: total,
      outputTokens: tokens,
      succeeded: true,
    );
  }
}

class _DeviceJob {
  const _DeviceJob(this.reply, this.contextTokens, this.outputTokens, this.scale);
  final SendPort reply;
  final int contextTokens;
  final int outputTokens;
  final double scale;
}

const int _hidden = 2048;

double _pass(Float32List a, Float32List b, int repeats) {
  var acc = 0.0;
  for (var r = 0; r < repeats; r++) {
    for (var i = 0; i < _hidden; i++) {
      acc += a[i] * b[i];
      b[i] = b[i] * 0.999 + a[i] * 0.001;
    }
  }
  return acc;
}

void _deviceWorker(_DeviceJob job) {
  final rng = math.Random(7);
  final a = Float32List(_hidden);
  final b = Float32List(_hidden);
  for (var i = 0; i < _hidden; i++) {
    a[i] = rng.nextDouble();
    b[i] = rng.nextDouble();
  }
  var sink = 0.0;
  // Prefill: ~16 hidden-size passes per context token.
  final prefillPasses = math.max(1, (job.contextTokens * 16 * job.scale).round());
  sink += _pass(a, b, prefillPasses);
  // First token.
  final perToken = math.max(1, ((32 + job.contextTokens / 32) * job.scale).round());
  sink += _pass(a, b, perToken);
  job.reply.send('first');
  for (var t = 1; t < job.outputTokens; t++) {
    sink += _pass(a, b, perToken);
  }
  // `sink` keeps the work observable so it cannot be optimised away.
  job.reply.send(sink.isNaN ? -1 : job.outputTokens);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/video_frame_extractor.dart';

void main() {
  test('keeps the first frame and reserves one full-span sample for the tail',
      () {
    const extractor = VideoFrameExtractor(ffmpegExecutable: '/test/ffmpeg');
    final arguments = extractor.buildArguments(
      '/input/customer.mp4',
      '/output/frame_%02d.jpg',
    );

    expect(
        arguments,
        containsAllInOrder(
            ['-vf', "select='eq(n,0)+gte(t-prev_selected_t,1)'"]));
    expect(arguments, containsAllInOrder(['-frames:v', '19']));
    expect(arguments, containsAllInOrder(['-start_number', '0']));
    expect(arguments.last, '/output/frame_%02d.jpg');
    expect(VideoFrameExtractor.maximumFrames, 20);
  });
}

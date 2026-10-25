#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed: %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)

static void encode(enum AVCodecID id, const char *name, int channels, int kbps) {
    const AVCodec *codec = avcodec_find_encoder(id);
    CHECK(codec && !strcmp(codec->name, name));
    CHECK(codec == avcodec_find_encoder_by_name(name));
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    CHECK(ctx);
    ctx->sample_rate = 48000;
    ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
    ctx->bit_rate = kbps * 1000;
    av_channel_layout_default(&ctx->ch_layout, channels);
    CHECK(avcodec_open2(ctx, codec, NULL) == 0);
    CHECK(ctx->frame_size == 1536);
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    CHECK(frame && packet);
    frame->format = ctx->sample_fmt;
    frame->sample_rate = ctx->sample_rate;
    frame->nb_samples = ctx->frame_size;
    CHECK(av_channel_layout_copy(&frame->ch_layout, &ctx->ch_layout) == 0);
    CHECK(av_frame_get_buffer(frame, 0) == 0);
    CHECK(av_samples_set_silence(frame->extended_data, 0, frame->nb_samples, channels, ctx->sample_fmt) == 0);
    CHECK(avcodec_send_frame(ctx, frame) == 0);
    CHECK(avcodec_receive_packet(ctx, packet) == 0);
    CHECK(packet->size > 2 && packet->data[0] == 0x0b && packet->data[1] == 0x77);
    printf("%s %dch %dkbps: registered, opened, encoded %d bytes\n", name, channels, kbps, packet->size);
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
}

int main(void) {
    CHECK(strstr(avcodec_configuration(), "--disable-all"));
    CHECK(!strstr(avcodec_configuration(), "--enable-nonfree"));
    CHECK(!avcodec_find_encoder(AV_CODEC_ID_OPUS));
    void *iterator = NULL;
    const AVCodec *codec;
    int encoders = 0;
    while ((codec = av_codec_iterate(&iterator))) {
        if (av_codec_is_encoder(codec)) ++encoders;
    }
    printf("Enabled encoders: %d\n", encoders);
    CHECK(encoders >= 2);
    puts(avcodec_configuration());
    puts(avcodec_license());
    for (int quality = 0; quality < 2; ++quality) {
        encode(AV_CODEC_ID_AC3, "ac3", 2, quality ? 192 : 128);
        encode(AV_CODEC_ID_EAC3, "eac3", 2, quality ? 192 : 128);
        encode(AV_CODEC_ID_AC3, "ac3", 6, quality ? 640 : 384);
        encode(AV_CODEC_ID_EAC3, "eac3", 6, quality ? 384 : 192);
    }
    return 0;
}

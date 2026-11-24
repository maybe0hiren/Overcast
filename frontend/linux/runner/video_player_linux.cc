#include "video_player_linux.h"

#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>

#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Custom FlPixelBufferTexture subclass for rendering GStreamer RGBA frames
struct _VideoPlayerTexture {
  FlPixelBufferTexture parent_instance;
  std::mutex mutex;
  std::vector<uint8_t> front_buffer;
  std::vector<uint8_t> back_buffer;
  uint32_t width = 0;
  uint32_t height = 0;
};

G_DECLARE_FINAL_TYPE(VideoPlayerTexture,
                     video_player_texture,
                     VIDEO_PLAYER,
                     TEXTURE,
                     FlPixelBufferTexture)

G_DEFINE_TYPE(VideoPlayerTexture,
              video_player_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean video_player_texture_copy_pixels(
    FlPixelBufferTexture* texture,
    const uint8_t** out_buffer,
    uint32_t* width,
    uint32_t* height,
    GError** error) {
  VideoPlayerTexture* self = VIDEO_PLAYER_TEXTURE(texture);
  std::lock_guard<std::mutex> lock(self->mutex);
  if (self->front_buffer.empty() || self->width == 0 || self->height == 0) {
    return FALSE;
  }
  self->back_buffer = self->front_buffer;
  *out_buffer = self->back_buffer.data();
  *width = self->width;
  *height = self->height;
  return TRUE;
}

static void video_player_texture_dispose(GObject* object) {
  VideoPlayerTexture* self = VIDEO_PLAYER_TEXTURE(object);
  self->front_buffer.~vector();
  self->back_buffer.~vector();
  self->mutex.~mutex();
  G_OBJECT_CLASS(video_player_texture_parent_class)->dispose(object);
}

static void video_player_texture_class_init(VideoPlayerTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      video_player_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = video_player_texture_dispose;
}

static void video_player_texture_init(VideoPlayerTexture* self) {
  new (&self->mutex) std::mutex();
  new (&self->front_buffer) std::vector<uint8_t>();
  new (&self->back_buffer) std::vector<uint8_t>();
  self->width = 0;
  self->height = 0;
}

static VideoPlayerTexture* video_player_texture_new() {
  return VIDEO_PLAYER_TEXTURE(
      g_object_new(video_player_texture_get_type(), nullptr));
}

namespace {

class LinuxGstVideoPlayer {
 public:
  LinuxGstVideoPlayer(FlBinaryMessenger* messenger,
                      FlTextureRegistrar* texture_registrar)
      : texture_registrar_(texture_registrar) {
    gst_init(nullptr, nullptr);

    texture_ = video_player_texture_new();
    // Create an initial 1x1 black pixel so Flutter Texture widget never errors before first frame
    {
      std::lock_guard<std::mutex> lock(texture_->mutex);
      texture_->width = 1;
      texture_->height = 1;
      texture_->front_buffer.assign(4, 0);
      texture_->front_buffer[3] = 255;
    }
    fl_texture_registrar_register_texture(texture_registrar_,
                                          FL_TEXTURE(texture_));
    texture_id_ = fl_texture_get_id(FL_TEXTURE(texture_));

    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    std::string channel_name =
        "overcast/video_player/events/" + std::to_string(texture_id_);
    event_channel_ = fl_event_channel_new(messenger, channel_name.c_str(),
                                          FL_METHOD_CODEC(codec));
  }

  ~LinuxGstVideoPlayer() { Dispose(); }

  int64_t texture_id() const { return texture_id_; }

  bool Open(const std::string& uri) {
    playbin_ = gst_element_factory_make("playbin", nullptr);
    if (!playbin_) return false;

    videoconvert_ = gst_element_factory_make("videoconvert", nullptr);
    appsink_ = gst_element_factory_make("appsink", nullptr);
    if (!videoconvert_ || !appsink_) return false;

    GstCaps* caps = gst_caps_from_string("video/x-raw,format=RGBA");
    g_object_set(G_OBJECT(appsink_), "caps", caps, "emit-signals", TRUE,
                 "sync", TRUE, "max-buffers", 2, "drop", TRUE, nullptr);
    gst_caps_unref(caps);

    g_signal_connect(appsink_, "new-sample", G_CALLBACK(OnNewSampleStatic),
                     this);
    g_signal_connect(playbin_, "source-setup", G_CALLBACK(OnSourceSetupStatic),
                     this);

    videobin_ = gst_bin_new("overcast_videobin");
    gst_bin_add_many(GST_BIN(videobin_), videoconvert_, appsink_, nullptr);
    gst_element_link(videoconvert_, appsink_);

    GstPad* pad = gst_element_get_static_pad(videoconvert_, "sink");
    GstPad* ghost_pad = gst_ghost_pad_new("sink", pad);
    gst_pad_set_active(ghost_pad, TRUE);
    gst_element_add_pad(videobin_, ghost_pad);
    gst_object_unref(pad);

    g_object_set(G_OBJECT(playbin_), "video-sink", videobin_, nullptr);
    g_object_set(G_OBJECT(playbin_), "uri", uri.c_str(), nullptr);

    // Enable ring-buffer / download buffering flags on playbin if available
    // GST_PLAY_FLAG_VIDEO (0x01) | GST_PLAY_FLAG_AUDIO (0x02) | GST_PLAY_FLAG_BUFFERING (0x100)
    gint flags = 0;
    g_object_get(G_OBJECT(playbin_), "flags", &flags, nullptr);
    flags |= (1 << 8);  // GST_PLAY_FLAG_BUFFERING
    g_object_set(G_OBJECT(playbin_), "flags", flags, "buffer-size",
                 8 * 1024 * 1024, nullptr);

    bus_ = gst_element_get_bus(playbin_);
    bus_watch_id_ =
        gst_bus_add_watch(bus_, (GstBusFunc)OnBusMessageStatic, this);

    GstStateChangeReturn ret =
        gst_element_set_state(playbin_, GST_STATE_PAUSED);
    return ret != GST_STATE_CHANGE_FAILURE;
  }

  void Play() {
    is_playing_ = true;
    if (playbin_) {
      gst_element_set_state(playbin_, GST_STATE_PLAYING);
    }
  }

  void Pause() {
    is_playing_ = false;
    if (playbin_) {
      gst_element_set_state(playbin_, GST_STATE_PAUSED);
    }
  }

  void SetLooping(bool looping) { is_looping_ = looping; }

  void SetVolume(double volume) {
    if (playbin_) {
      if (volume < 0.0) volume = 0.0;
      if (volume > 1.0) volume = 1.0;
      g_object_set(G_OBJECT(playbin_), "volume", volume, nullptr);
    }
  }

  void SetPlaybackSpeed(double speed) {
    if (speed <= 0.0) return;
    playback_rate_ = speed;
    if (is_initialized_) {
      SeekTo(GetPosition());
    }
  }

  int64_t GetPosition() {
    if (!playbin_) return 0;
    // Periodically re-check duration if it changed or became available later
    int64_t dur = GetDuration();
    if (dur > 0 && dur != last_reported_duration_ms_) {
      last_reported_duration_ms_ = dur;
      SendDurationUpdate(dur);
    }

    gint64 pos = 0;
    if (gst_element_query_position(playbin_, GST_FORMAT_TIME, &pos) &&
        pos >= 0) {
      int64_t pos_ms = pos / GST_MSECOND;
      last_known_position_ms_ = pos_ms;
      pending_seek_ms_ = -1;
      return pos_ms;
    }
    if (pending_seek_ms_ >= 0) {
      return pending_seek_ms_;
    }
    return last_known_position_ms_;
  }

  int64_t GetDuration() {
    if (!playbin_) return 0;
    gint64 dur = 0;
    if (gst_element_query_duration(playbin_, GST_FORMAT_TIME, &dur) && dur > 0) {
      return dur / GST_MSECOND;
    }
    return 0;
  }

  void SeekTo(int64_t position_ms) {
    if (!playbin_) return;
    if (position_ms < 0) position_ms = 0;
    int64_t dur = GetDuration();
    if (dur > 0 && position_ms > dur) {
      position_ms = dur;
    }
    pending_seek_ms_ = position_ms;
    last_known_position_ms_ = position_ms;

    // Wait briefly if pipeline is still transitioning states before issuing seek
    GstState state = GST_STATE_NULL;
    GstState pending = GST_STATE_VOID_PENDING;
    gst_element_get_state(playbin_, &state, &pending, 25 * GST_MSECOND);

    GstSeekFlags flags = static_cast<GstSeekFlags>(
        GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT | GST_SEEK_FLAG_SNAP_NEAREST);

    gboolean ok = gst_element_seek(
        playbin_, playback_rate_, GST_FORMAT_TIME, flags, GST_SEEK_TYPE_SET,
        position_ms * GST_MSECOND, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE);

    if (!ok) {
      // Fallback to accurate flush seek
      gst_element_seek(
          playbin_, playback_rate_, GST_FORMAT_TIME,
          static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                    GST_SEEK_FLAG_ACCURATE),
          GST_SEEK_TYPE_SET, position_ms * GST_MSECOND, GST_SEEK_TYPE_NONE,
          GST_CLOCK_TIME_NONE);
    }

    if (is_playing_) {
      gst_element_set_state(playbin_, GST_STATE_PLAYING);
    }
  }

  void Dispose() {
    if (disposed_) return;
    disposed_ = true;

    if (init_retry_timer_id_ != 0) {
      g_source_remove(init_retry_timer_id_);
      init_retry_timer_id_ = 0;
    }
    if (bus_watch_id_ != 0) {
      g_source_remove(bus_watch_id_);
      bus_watch_id_ = 0;
    }
    if (bus_) {
      gst_object_unref(bus_);
      bus_ = nullptr;
    }
    if (playbin_) {
      gst_element_set_state(playbin_, GST_STATE_NULL);
      gst_object_unref(playbin_);
      playbin_ = nullptr;
    }
    if (texture_ && texture_registrar_) {
      fl_texture_registrar_unregister_texture(texture_registrar_,
                                              FL_TEXTURE(texture_));
      g_object_unref(texture_);
      texture_ = nullptr;
    }
    if (event_channel_) {
      g_clear_object(&event_channel_);
    }
  }

 private:
  static void OnSourceSetupStatic(GstElement* playbin,
                                  GstElement* source,
                                  gpointer user_data) {
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(source),
                                     "ssl-strict") != nullptr) {
      g_object_set(G_OBJECT(source), "ssl-strict", FALSE, nullptr);
    }
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(source),
                                     "timeout") != nullptr) {
      g_object_set(G_OBJECT(source), "timeout", 30, nullptr);
    }
  }

  struct FrameNotification {
    FlTextureRegistrar* registrar;
    FlTexture* texture;
  };

  static gboolean NotifyFrameOnMainThread(gpointer data) {
    FrameNotification* notif = static_cast<FrameNotification*>(data);
    fl_texture_registrar_mark_texture_frame_available(notif->registrar,
                                                      notif->texture);
    g_object_unref(notif->texture);
    delete notif;
    return G_SOURCE_REMOVE;
  }

  static GstFlowReturn OnNewSampleStatic(GstElement* sink, gpointer user_data) {
    LinuxGstVideoPlayer* self = static_cast<LinuxGstVideoPlayer*>(user_data);
    if (self->disposed_) return GST_FLOW_EOS;

    GstSample* sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    if (!sample) return GST_FLOW_ERROR;

    GstCaps* caps = gst_sample_get_caps(sample);
    GstBuffer* buffer = gst_sample_get_buffer(sample);

    if (caps && buffer) {
      GstVideoInfo info;
      if (gst_video_info_from_caps(&info, caps)) {
        GstMapInfo map;
        if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
          uint32_t w = GST_VIDEO_INFO_WIDTH(&info);
          uint32_t h = GST_VIDEO_INFO_HEIGHT(&info);
          int stride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);

          if (w > 0 && h > 0 && self->texture_) {
            {
              std::lock_guard<std::mutex> lock(self->texture_->mutex);
              self->texture_->width = w;
              self->texture_->height = h;
              size_t tight_row = static_cast<size_t>(w) * 4;
              self->texture_->front_buffer.resize(tight_row * h);

              if (static_cast<size_t>(stride) == tight_row &&
                  map.size >= tight_row * h) {
                std::memcpy(self->texture_->front_buffer.data(), map.data,
                            tight_row * h);
              } else {
                for (uint32_t row = 0; row < h; ++row) {
                  size_t src_off = static_cast<size_t>(row) * stride;
                  if (src_off + tight_row <= map.size) {
                    std::memcpy(
                        self->texture_->front_buffer.data() + row * tight_row,
                        map.data + src_off, tight_row);
                  }
                }
              }
              self->video_width_ = static_cast<int>(w);
              self->video_height_ = static_cast<int>(h);
            }

            if (self->texture_registrar_ && self->texture_) {
              auto* notif = new FrameNotification{
                  self->texture_registrar_,
                  FL_TEXTURE(g_object_ref(self->texture_))};
              g_main_context_invoke(nullptr, NotifyFrameOnMainThread, notif);
            }
          }
          gst_buffer_unmap(buffer, &map);
        }
      }
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  static gboolean InitRetryTimerCallback(gpointer user_data) {
    LinuxGstVideoPlayer* self = static_cast<LinuxGstVideoPlayer*>(user_data);
    if (self->disposed_ || self->is_initialized_) {
      self->init_retry_timer_id_ = 0;
      return G_SOURCE_REMOVE;
    }
    self->init_retry_count_++;
    if (self->GetDuration() > 0 || self->init_retry_count_ >= 25) {
      self->init_retry_timer_id_ = 0;
      self->SendInitializedIfReady(true);
      return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
  }

  static gboolean OnBusMessageStatic(GstBus* bus,
                                     GstMessage* msg,
                                     gpointer user_data) {
    LinuxGstVideoPlayer* self = static_cast<LinuxGstVideoPlayer*>(user_data);
    if (self->disposed_) return FALSE;

    switch (GST_MESSAGE_TYPE(msg)) {
      case GST_MESSAGE_ASYNC_DONE: {
        self->pending_seek_ms_ = -1;
        if (!self->is_initialized_) {
          self->SendInitializedIfReady(false);
        } else {
          int64_t dur = self->GetDuration();
          if (dur > 0 && dur != self->last_reported_duration_ms_) {
            self->last_reported_duration_ms_ = dur;
            self->SendDurationUpdate(dur);
          }
        }
        break;
      }
      case GST_MESSAGE_STATE_CHANGED: {
        if (GST_MESSAGE_SRC(msg) == GST_OBJECT(self->playbin_)) {
          GstState old_state, new_state, pending_state;
          gst_message_parse_state_changed(msg, &old_state, &new_state,
                                          &pending_state);
          if (new_state >= GST_STATE_PAUSED && !self->is_initialized_) {
            self->SendInitializedIfReady(false);
          }
        }
        break;
      }
      case GST_MESSAGE_DURATION_CHANGED: {
        if (!self->is_initialized_) {
          self->SendInitializedIfReady(false);
        } else {
          int64_t dur = self->GetDuration();
          if (dur > 0 && dur != self->last_reported_duration_ms_) {
            self->last_reported_duration_ms_ = dur;
            self->SendDurationUpdate(dur);
          }
        }
        break;
      }
      case GST_MESSAGE_BUFFERING: {
        gint percent = 0;
        gst_message_parse_buffering(msg, &percent);
        if (self->event_channel_) {
          g_autoptr(FlValue) bmap = fl_value_new_map();
          fl_value_set_string_take(
              bmap, "event",
              fl_value_new_string(percent < 100 ? "bufferingStart"
                                                : "bufferingEnd"));
          fl_event_channel_send(self->event_channel_, bmap, nullptr, nullptr);
        }
        break;
      }
      case GST_MESSAGE_EOS: {
        if (self->is_looping_) {
          self->SeekTo(0);
          self->Play();
        } else {
          self->SendCompleted();
        }
        break;
      }
      case GST_MESSAGE_ERROR: {
        GError* err = nullptr;
        gchar* debug = nullptr;
        gst_message_parse_error(msg, &err, &debug);
        if (self->event_channel_ && err) {
          fl_event_channel_send_error(self->event_channel_, "VideoError",
                                      err->message, nullptr, nullptr, nullptr);
        }
        if (err) g_error_free(err);
        if (debug) g_free(debug);
        break;
      }
      default:
        break;
    }
    return TRUE;
  }

  void SendInitializedIfReady(bool force) {
    if (is_initialized_ || !event_channel_) return;

    int64_t dur = GetDuration();
    if (dur <= 0 && !force) {
      // Wait for demuxer to parse duration over HTTP stream
      if (init_retry_timer_id_ == 0) {
        init_retry_count_ = 0;
        init_retry_timer_id_ =
            g_timeout_add(80, InitRetryTimerCallback, this);
      }
      return;
    }

    if (init_retry_timer_id_ != 0) {
      g_source_remove(init_retry_timer_id_);
      init_retry_timer_id_ = 0;
    }

    int w = video_width_;
    int h = video_height_;
    if (w <= 0 || h <= 0) {
      if (appsink_) {
        GstPad* pad = gst_element_get_static_pad(appsink_, "sink");
        if (pad) {
          GstCaps* caps = gst_pad_get_current_caps(pad);
          if (caps) {
            GstVideoInfo info;
            if (gst_video_info_from_caps(&info, caps)) {
              w = GST_VIDEO_INFO_WIDTH(&info);
              h = GST_VIDEO_INFO_HEIGHT(&info);
            }
            gst_caps_unref(caps);
          }
          gst_object_unref(pad);
        }
      }
    }

    if (w <= 0) w = 1280;
    if (h <= 0) h = 720;

    is_initialized_ = true;
    last_reported_duration_ms_ = dur;

    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "event", fl_value_new_string("initialized"));
    fl_value_set_string_take(map, "duration", fl_value_new_int(dur));
    fl_value_set_string_take(map, "width", fl_value_new_int(w));
    fl_value_set_string_take(map, "height", fl_value_new_int(h));
    fl_event_channel_send(event_channel_, map, nullptr, nullptr);

    if (is_playing_) {
      Play();
    }
  }

  void SendDurationUpdate(int64_t duration_ms) {
    if (!event_channel_ || duration_ms <= 0) return;
    int64_t buffered_end = duration_ms;
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "event",
                             fl_value_new_string("durationUpdate"));
    fl_value_set_string_take(map, "duration", fl_value_new_int(duration_ms));
    fl_value_set_string_take(map, "bufferedEnd",
                             fl_value_new_int(buffered_end));
    fl_event_channel_send(event_channel_, map, nullptr, nullptr);
  }

  void SendCompleted() {
    if (!event_channel_) return;
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "event", fl_value_new_string("completed"));
    fl_event_channel_send(event_channel_, map, nullptr, nullptr);
  }

  int64_t texture_id_ = 0;
  FlTextureRegistrar* texture_registrar_ = nullptr;
  VideoPlayerTexture* texture_ = nullptr;
  FlEventChannel* event_channel_ = nullptr;

  GstElement* playbin_ = nullptr;
  GstElement* videobin_ = nullptr;
  GstElement* videoconvert_ = nullptr;
  GstElement* appsink_ = nullptr;
  GstBus* bus_ = nullptr;
  guint bus_watch_id_ = 0;
  guint init_retry_timer_id_ = 0;
  int init_retry_count_ = 0;

  int video_width_ = 0;
  int video_height_ = 0;
  int64_t last_known_position_ms_ = 0;
  int64_t pending_seek_ms_ = -1;
  int64_t last_reported_duration_ms_ = 0;
  double playback_rate_ = 1.0;
  bool is_initialized_ = false;
  bool is_playing_ = false;
  bool is_looping_ = false;
  bool disposed_ = false;
};

static FlBinaryMessenger* g_messenger = nullptr;
static FlTextureRegistrar* g_texture_registrar = nullptr;
static FlMethodChannel* g_method_channel = nullptr;
static std::map<int64_t, std::unique_ptr<LinuxGstVideoPlayer>> g_players;

static void HandleMethodCall(FlMethodChannel* channel,
                             FlMethodCall* method_call,
                             gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (std::strcmp(method, "init") == 0) {
    g_players.clear();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (std::strcmp(method, "create") == 0) {
    FlValue* uri_val =
        (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP)
            ? fl_value_lookup_string(args, "uri")
            : nullptr;
    if (!uri_val || fl_value_get_type(uri_val) != FL_VALUE_TYPE_STRING) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "InvalidArgs", "Missing uri string", nullptr));
    } else {
      std::string uri = fl_value_get_string(uri_val);
      auto player = std::make_unique<LinuxGstVideoPlayer>(
          g_messenger, g_texture_registrar);
      int64_t tex_id = player->texture_id();
      if (!player->Open(uri)) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "GStreamerError", "Failed to initialize GStreamer pipeline",
            nullptr));
      } else {
        g_players[tex_id] = std::move(player);
        g_autoptr(FlValue) res = fl_value_new_map();
        fl_value_set_string_take(res, "textureId", fl_value_new_int(tex_id));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
      }
    }
  } else {
    int64_t texture_id = -1;
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* tid_val = fl_value_lookup_string(args, "textureId");
      if (tid_val && fl_value_get_type(tid_val) == FL_VALUE_TYPE_INT) {
        texture_id = fl_value_get_int(tid_val);
      }
    }

    auto it = g_players.find(texture_id);
    if (it == g_players.end()) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NoPlayer", "Video player not found", nullptr));
    } else {
      auto& player = it->second;
      if (std::strcmp(method, "dispose") == 0) {
        g_players.erase(it);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "play") == 0) {
        player->Play();
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "pause") == 0) {
        player->Pause();
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "setLooping") == 0) {
        FlValue* v = fl_value_lookup_string(args, "looping");
        bool looping =
            (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL)
                ? fl_value_get_bool(v)
                : false;
        player->SetLooping(looping);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "setVolume") == 0) {
        FlValue* v = fl_value_lookup_string(args, "volume");
        double vol =
            (v && fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
                ? fl_value_get_float(v)
                : 1.0;
        player->SetVolume(vol);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "setPlaybackSpeed") == 0) {
        FlValue* v = fl_value_lookup_string(args, "speed");
        double spd =
            (v && fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
                ? fl_value_get_float(v)
                : 1.0;
        player->SetPlaybackSpeed(spd);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "seekTo") == 0) {
        FlValue* v = fl_value_lookup_string(args, "position");
        int64_t pos =
            (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT)
                ? fl_value_get_int(v)
                : 0;
        player->SeekTo(pos);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else if (std::strcmp(method, "position") == 0) {
        int64_t pos = player->GetPosition();
        g_autoptr(FlValue) res = fl_value_new_int(pos);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
      } else if (std::strcmp(method, "duration") == 0) {
        int64_t dur = player->GetDuration();
        g_autoptr(FlValue) res = fl_value_new_int(dur);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(res));
      } else {
        response =
            FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
      }
    }
  }

  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

void video_player_linux_register_with_registrar(FlPluginRegistrar* registrar) {
  g_messenger = fl_plugin_registrar_get_messenger(registrar);
  g_texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_method_channel = fl_method_channel_new(
      g_messenger, "overcast/video_player", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_method_channel, HandleMethodCall,
                                            nullptr, nullptr);
}

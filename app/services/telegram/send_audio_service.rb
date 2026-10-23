require 'tmpdir'
require 'timeout'

# Reuse the attachment transport, channel context, and Telegram response parser.
class Telegram::SendAudioService < Telegram::SendAttachmentsService
  # Upload audio bytes directly: Telegram must not fetch private/expiring storage URLs.
  # Keep music files as audio; normalize browser/native recordings to voice notes.
  def perform(attachments)
    response = nil
    attachments.each do |attachment|
      response = audio_request(attachment[:attachment])
      break unless response.success?
    end
    response
  end

  private

  def audio_request(attachment)
    filename = attachment.file.filename.to_s
    attachment.file.blob.open do |source|
      return upload(source.path, method: 'sendAudio', field: :audio, filename: filename) if %w[.mp3 .m4a].include?(File.extname(filename).downcase)

      Dir.mktmpdir('telegram-voice-') do |dir|
        voice_path = File.join(dir, 'voice.ogg')
        return upload(voice_path, method: 'sendVoice', field: :voice, content_type: 'audio/ogg') if convert_voice(source.path, voice_path)
      end

      Rails.logger.warn "Message Id: #{message.id} - Voice conversion failed; uploading original document"
      upload(source.path, filename: filename)
    end
  end

  def upload(path, **)
    send_file(channel.chat_id(message), path, channel.reply_to_message_id(message), **)
  end

  def convert_voice(source, destination)
    pid = Process.spawn('ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                        '-protocol_whitelist', 'file,pipe', '-i', source, '-map', '0:a:0', '-vn',
                        '-ac', '1', '-ar', '48000', '-c:a', 'libopus', '-b:a', '32k', destination,
                        in: File::NULL, out: File::NULL, err: File::NULL)
    _, status = Timeout.timeout(60) { Process.wait2(pid) }
    status.success? && File.size?(destination)
  rescue Errno::ENOENT
    false
  rescue Timeout::Error
    terminate_conversion(pid)
    false
  end

  def terminate_conversion(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # The converter may have exited just as the timeout fired.
    nil
  end
end

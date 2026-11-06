# Remove the remote copy before erasing local content. Never log Telegram URLs/tokens.
class Telegram::RemoveMessageService
  class RemovalError < StandardError; end

  REDACTED_TEXT = 'Сообщение удалено'.freeze
  FAILURE_MESSAGE = 'Telegram removal failed. The message has been kept in Chatwoot. Please retry.'.freeze

  def initialize(message:)
    @message = message
  end

  def perform
    return unless enabled? && @message.inbox.telegram? && !@message.private? && @message.outgoing?
    return @message.content_attributes['telegram_removal'] if @message.content_attributes['deleted']

    validate_delivery!
    response = request('deleteMessage')
    return receipt('deleted') if response['ok'] == true || already_absent?(response)

    if response['error_code'] == 400 && @message.attachments.empty?
      response = request('editMessageText', text: REDACTED_TEXT)
      return receipt('redacted') if response['ok'] == true || already_redacted?(response)
    end

    raise RemovalError, FAILURE_MESSAGE
  rescue Timeout::Error, SocketError, IOError, SystemCallError, JSON::ParserError, OpenSSL::SSL::SSLError
    raise RemovalError, FAILURE_MESSAGE
  end

  private

  def enabled?
    return false unless ENV['TELEGRAM_REMOTE_DELETE_ENABLED'] == 'true'

    allowlist = ENV.fetch('TELEGRAM_REMOTE_DELETE_CONVERSATIONS', '').split(',').map(&:strip)
    allowlist.empty? || allowlist.include?("#{@message.account_id}:#{@message.conversation.display_id}")
  end

  def validate_delivery!
    # The legacy sender retains only one ID for albums and text + attachment sends.
    # Refuse these instead of claiming that every remote part has disappeared.
    multiple_parts = @message.attachments.size > 1 || (@message.attachments.any? && @message.outgoing_content.present?)
    valid_id = @message.source_id.to_s.match?(/\A[1-9]\d*\z/)
    business = @message.conversation.additional_attributes['business_connection_id'].present?
    raise RemovalError, FAILURE_MESSAGE unless valid_id && !multiple_parts && !business && @message.status == 'sent'
  end

  def request(method, **extra)
    channel = @message.inbox.channel
    response = HTTParty.post("#{channel.telegram_api_url}/#{method}",
                             body: { chat_id: channel.chat_id(@message), message_id: @message.source_id, **extra },
                             open_timeout: 3, read_timeout: 5, write_timeout: 5)
    parsed = response.parsed_response
    raise RemovalError, FAILURE_MESSAGE unless parsed.is_a?(Hash)

    parsed
  end

  def already_absent?(response)
    response['error_code'] == 400 && response['description'] == 'Bad Request: message to delete not found'
  end

  def already_redacted?(response)
    response['error_code'] == 400 && response['description'].to_s.start_with?('Bad Request: message is not modified')
  end

  def receipt(status)
    { 'status' => status, 'message_id' => @message.source_id.to_s, 'completed_at' => Time.now.utc.iso8601 }
  end
end

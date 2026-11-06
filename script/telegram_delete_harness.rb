# Run in the candidate image with --network none. No Rails DB or inbox connection.
require 'active_support/all'
require 'httparty'
require 'ostruct'
module Telegram
end
require_relative '../app/services/telegram/remove_message_service'

module Api
  module V1
    module Accounts
      module Conversations
        class BaseController
          def self.before_action(*); end
        end
      end
    end
  end
end
module ActiveRecord
  class Base
    def self.transaction
      yield
    end
  end
end
require_relative '../app/controllers/api/v1/accounts/conversations/messages_controller'

class DeleteHarness
  class << self
    attr_accessor :responses, :requests
  end

  def self.check(name)
    self.requests = []
    yield
    puts "PASS #{name}"
  end

  def self.assert(condition)
    raise 'Assertion failed' unless condition
  end

  def self.message(**overrides)
    attachments = []
    def attachments.destroy_all
      clear
    end
    channel = OpenStruct.new(telegram_api_url: 'https://invalid.example/bot-not-a-secret')
    def channel.chat_id(_message)
      123
    end
    message = OpenStruct.new({ id: 100, account_id: 1, source_id: '456', status: 'sent', content: 'Test', content_attributes: {},
                               conversation: OpenStruct.new(display_id: 28, additional_attributes: {}),
                               inbox: OpenStruct.new(telegram?: true, channel: channel), private?: false, outgoing?: true,
                               attachments: attachments, outgoing_content: 'Test' }.merge(overrides))
    def message.update!(attributes)
      attributes.each { |key, value| self[key] = value }
    end
    message
  end

  def self.remove(message)
    controller = Api::V1::Accounts::Conversations::MessagesController.new
    controller.define_singleton_method(:message) { message }
    controller.define_singleton_method(:render_could_not_create_error) { |error| @error = error }
    controller.destroy
    controller.instance_variable_get(:@error)
  end
end

module HTTParty
  def self.post(url, **options)
    DeleteHarness.requests << [url.split('/').last, options]
    response = DeleteHarness.responses.shift
    raise response if response.is_a?(Exception)
    raise 'Unexpected HTTP request' if response.nil?

    OpenStruct.new(parsed_response: response)
  end
end

ENV['TELEGRAM_REMOTE_DELETE_ENABLED'] = 'true'
ENV['TELEGRAM_REMOTE_DELETE_CONVERSATIONS'] = '1:28'
ok = { 'ok' => true, 'result' => true }
denied = { 'ok' => false, 'error_code' => 400, 'description' => "Bad Request: message can't be deleted" }

DeleteHarness.check('delete first; local tombstone only after remote success') do
  DeleteHarness.responses = [ok]
  message = DeleteHarness.message
  DeleteHarness.assert(DeleteHarness.remove(message).nil?)
  DeleteHarness.assert(message.content_attributes[:telegram_removal]['status'] == 'deleted')
  DeleteHarness.assert(DeleteHarness.requests.map(&:first) == ['deleteMessage'])
  DeleteHarness.assert(DeleteHarness.requests[0][1][:body] == { chat_id: 123, message_id: '456' })
end

DeleteHarness.check('explicit delete refusal falls back to neutral edit of same message') do
  DeleteHarness.responses = [denied, ok]
  message = DeleteHarness.message
  DeleteHarness.assert(DeleteHarness.remove(message).nil?)
  DeleteHarness.assert(message.content_attributes[:telegram_removal]['status'] == 'redacted')
  DeleteHarness.assert(DeleteHarness.requests.map(&:first) == %w[deleteMessage editMessageText])
  DeleteHarness.assert(DeleteHarness.requests.last[1][:body][:text] == 'Сообщение удалено')
end

DeleteHarness.check('both methods fail: keep original locally, return error') do
  DeleteHarness.responses = [denied, denied]
  message = DeleteHarness.message
  DeleteHarness.assert(DeleteHarness.remove(message).present?)
  DeleteHarness.assert(message.content == 'Test' && message.content_attributes.empty?)
end

[Timeout::Error.new('sensitive URL must never escape'), { 'ok' => false, 'error_code' => 429 },
 { 'ok' => false, 'error_code' => 403 }, { 'ok' => false, 'error_code' => 500 }, 'malformed'].each do |failure|
  DeleteHarness.check("ambiguous/permission/rate-limit failure #{failure.class}: no fallback or local erase") do
    DeleteHarness.responses = [failure]
    message = DeleteHarness.message
    error = DeleteHarness.remove(message)
    DeleteHarness.assert(error == Telegram::RemoveMessageService::FAILURE_MESSAGE)
    DeleteHarness.assert(message.content == 'Test' && DeleteHarness.requests.size == 1)
  end
end

DeleteHarness.check('already absent remote copy is an idempotent success') do
  DeleteHarness.responses = [{ 'ok' => false, 'error_code' => 400, 'description' => 'Bad Request: message to delete not found' }]
  DeleteHarness.assert(DeleteHarness.remove(DeleteHarness.message).nil?)
  DeleteHarness.assert(DeleteHarness.requests.size == 1)
end

[{ private?: true }, { outgoing?: false }, { inbox: OpenStruct.new(telegram?: false) },
 { account_id: 4 }, { conversation: OpenStruct.new(display_id: 29) }].each do |overrides|
  DeleteHarness.check("private/incoming/other channel or canary scope #{overrides.keys}") do
    DeleteHarness.responses = []
    DeleteHarness.assert(DeleteHarness.remove(DeleteHarness.message(**overrides)).nil?)
    DeleteHarness.assert(DeleteHarness.requests.empty?)
  end
end

[{ source_id: nil }, { source_id: 'invalid' }, { status: 'pending' }, { attachments: [1, 2] },
 { attachments: [1] }, { conversation: OpenStruct.new(display_id: 28, additional_attributes: { 'business_connection_id' => 'abc' }) }].each do |overrides|
  DeleteHarness.check("unsupported or undelivered message #{overrides.keys}: no erase") do
    DeleteHarness.responses = []
    message = DeleteHarness.message(**overrides)
    DeleteHarness.assert(DeleteHarness.remove(message).present?)
    DeleteHarness.assert(message.content == 'Test' && DeleteHarness.requests.empty?)
  end
end

DeleteHarness.check('single attachment without separate text can be deleted; cannot be redacted') do
  attachments = [1]
  def attachments.destroy_all
    clear
  end
  DeleteHarness.responses = [denied]
  message = DeleteHarness.message(attachments: attachments, outgoing_content: '')
  DeleteHarness.assert(DeleteHarness.remove(message).present?)
  DeleteHarness.assert(attachments == [1] && DeleteHarness.requests.size == 1)
  DeleteHarness.responses = [ok]
  DeleteHarness.assert(DeleteHarness.remove(message).nil?)
  DeleteHarness.assert(attachments.empty?)
end

DeleteHarness.check('disabled feature retains previous local-only behavior') do
  ENV['TELEGRAM_REMOTE_DELETE_ENABLED'] = 'false'
  DeleteHarness.responses = []
  DeleteHarness.assert(DeleteHarness.remove(DeleteHarness.message).nil?)
  DeleteHarness.assert(DeleteHarness.requests.empty?)
end
puts 'All Telegram deletion checks passed (isolated, no external requests).'

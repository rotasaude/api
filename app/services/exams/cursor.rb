# Cursor das listas de exame: (created_at, id) decrescentes.
module Exams
  module Cursor
    class Invalid < StandardError; end

    module_function

    def encode(order) = Base64.urlsafe_encode64("#{order.created_at.utc.iso8601(6)}|#{order.id}", padding: false)

    def decode(raw)
      return nil if raw.blank?
      raise Invalid unless raw.is_a?(String)

      at, id = Base64.urlsafe_decode64(raw).split("|", 2)
      raise Invalid unless id&.match?(BaseController::UUID)

      [ Time.iso8601(at), id ]
    rescue ArgumentError
      raise Invalid
    end
  end
end

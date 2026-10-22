require "base64"

# Cursor opaco das listas (contrato: envelope com next_before): instante
# com microssegundos e id.
module CareLines
  module Cursor
    Invalid = Class.new(StandardError)
    Position = Data.define(:at, :id)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    INSTANT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

    module_function

    def encode(at, id) = Base64.urlsafe_encode64("#{at.utc.iso8601(6)}|#{id}", padding: false)

    def decode(raw)
      return nil if raw.nil? || raw == ""
      raise Invalid unless raw.is_a?(String)

      at, id = Base64.urlsafe_decode64(raw).split("|", 2)
      raise Invalid unless at.to_s.match?(INSTANT) && id.to_s.match?(UUID)

      Position.new(at: Time.iso8601(at), id: id.downcase)
    rescue ArgumentError
      raise Invalid
    end

    def before(scope, position, column)
      return scope if position.nil?

      table = scope.klass.quoted_table_name
      scope.where("(#{table}.#{column}, #{table}.id) < (?, ?)", position.at, position.id)
    end
  end
end

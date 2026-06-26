# Valor de retorno único de todo Command. Imutável. Ver ADR-0006.
class Result
  attr_reader :reason, :message, :details, :payload

  def self.ok(payload = {})
    new(success: true, payload: payload)
  end

  def self.fail(reason, message: nil, details: {})
    new(success: false, reason: reason.to_sym, message: message, details: details)
  end

  def initialize(success:, payload: {}, reason: nil, message: nil, details: {})
    @success = success
    @payload = payload
    @reason = reason
    @message = message
    @details = details
    freeze
  end

  def ok?       = @success
  def failure?  = !@success

  def to_h
    if ok?
      { ok: true, payload: payload }
    else
      { ok: false, reason: reason, message: message, details: details }.compact
    end
  end

  def deconstruct_keys(_keys)
    { ok?: ok?, failure?: failure?, reason: reason, payload: payload }
  end
end

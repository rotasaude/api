# app/models/nursing_protocol.rb
# Protocolo municipal de enfermagem (COFEN 801/2026; ADR 0033): título, número
# e ano nunca mudam; editar é criar versão. Vigente = a versão de maior número
# cuja vigência cobre a data.
class NursingProtocol < ApplicationRecord
  has_many :versions, class_name: "NursingProtocolVersion", dependent: :restrict_with_exception

  def current_version(on: Time.zone.today)
    versions.where(valid_from: ..on).where("valid_until IS NULL OR valid_until >= ?", on).order(version: :desc).first
  end
end

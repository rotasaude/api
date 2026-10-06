# Tipo de atendimento da cidade (ADR 0029 §3.1): base da plataforma copiada
# (origin platform) e tipos da cidade (origin city). Desativar nunca quebra
# pedido nem horário: eles guardam a key. key e origin nunca mudam (trigger).
class AppointmentType < ApplicationRecord
  ORIGINS = %w[platform city].freeze
  KEY = /\A[a-z][a-z0-9_]{1,40}\z/

  scope :active_types, -> { where(active: true) }
  scope :listed, -> { order(:position, :name) }

  def platform? = origin == "platform"
end

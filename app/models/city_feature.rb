# Interruptor de funcionalidade por cidade (ADR 0028; spec 2026-10-05 §3.1), no
# banco de PLATAFORMA. Só o maintenance escreve (Platform::Features.set!).
class CityFeature < PlatformRecord
  belongs_to :city
  belongs_to :changed_by_maintainer, class_name: "Maintainer"

  validates :key, inclusion: { in: ->(_) { Platform::Features::KEYS } }
  validates :changed_at, presence: true
end

# Base de onde saem os recortes de mapa por município (módulo 24c, ADR 0053;
# Q23, Q32): um recorte grande (o país; o estado em desenvolvimento) da build
# pública do Protomaps, guardado no serviço do Active Storage. Uma por versão
# (a data da build); o arquivo só existe na `ready`.
class FieldMapBase < PlatformRecord
  validates :state, inclusion: { in: FieldMaps::Catalog::BASE_STATES }
  validates :error_code, inclusion: { in: FieldMaps::Catalog::ERROR_CODES }, allow_nil: true

  # A base que vale: a pronta de maior versão.
  def self.current = where(state: "ready").order(version: :desc).first

  def ready? = state == "ready"
  def age_days(today = Time.zone.today) = (today - version).to_i

  def inspect = "#<FieldMapBase version=#{version&.iso8601} state=#{state}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)
end

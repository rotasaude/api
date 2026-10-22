# Versão do catálogo-base de uma linha de cuidado (ADR 0040). Imutável.
class CareLineTemplate < PlatformRecord
  def self.current(key) = where(key: key.to_s).order(version: :desc).first

  def self.latest
    rows = select("DISTINCT ON (key) care_line_templates.*").order(:key, version: :desc).to_a.index_by(&:key)
    CareLines::Catalog::TEMPLATE_KEYS.filter_map { |key| rows[key] }
  end

  def readonly? = persisted?
end

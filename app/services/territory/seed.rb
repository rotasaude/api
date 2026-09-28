require "yaml"

# Carga dos bairros de uma cidade (ADR 0023; spec 2026-09-28 §3.4, com a
# chave de semente decidida em 2026-09-28). Casa cada item do YAML com a linha
# pela `key` (neighborhoods.seed_key), NUNCA pelo nome: um bairro renomeado no
# dashboard não é recriado nem renomeado. Cria só o que falta; nunca altera
# nem desativa o que existe, e só liga cobertura em bairro criado NESTA carga
# — cobertura editada no dashboard prevalece. Nome já usado por outro bairro
# (manual, sem chave) vira aviso: sem duplicado e sem adotar a chave. Unidade
# é achada pelo nome, sem diferenciar maiúsculas, entre as ativas; a que não
# for achada vira aviso. Roda na cidade da conexão corrente: quem chama
# escolhe (city:territory:seed usa CityConnection.with).
module Territory
  class Seed
    Report = Struct.new(:created, :existing, :warnings, keyword_init: true)

    def self.path_for(slug)
      Rails.root.join("db/seeds/territory/#{slug}.yml")
    end

    def self.call(path:)
      data = YAML.safe_load_file(path)
      entries = data.is_a?(Hash) ? Array(data["neighborhoods"]) : []
      report = Report.new(created: 0, existing: 0, warnings: [])
      entries.each { |entry| load_entry(entry, report) }
      report
    end

    def self.load_entry(entry, report)
      entry = {} unless entry.is_a?(Hash)
      name = entry["name"].to_s.squish
      key = entry["key"].to_s.strip
      return report.warnings << "entrada sem nome: #{entry.inspect}" if name.empty?
      return report.warnings << "bairro #{name}: entrada sem key" if key.empty?
      return report.existing += 1 if Neighborhood.exists?(seed_key: key)
      if Neighborhood.named(name).exists?
        return report.warnings << "bairro #{name}: já existe um bairro com esse nome fora da semente (key #{key}) — pulado"
      end

      created = CreateNeighborhood.call(name: name, by: nil, source: "seed", seed_key: key)
      return report.warnings << "bairro #{name}: #{created.reason}" if created.failure?

      report.created += 1
      unit_ids = Array(entry["units"]).filter_map { |unit_name| active_unit_id(unit_name, name, report) }
      return if unit_ids.empty?

      covered = ReplaceCoverage.call(neighborhood: created.payload[:neighborhood], health_unit_ids: unit_ids, by: nil)
      report.warnings << "cobertura de #{name}: #{covered.reason}" if covered.failure?
    end

    def self.active_unit_id(unit_name, neighborhood_name, report)
      unit = HealthUnit.where(active: true).find_by("lower(name) = lower(?)", unit_name.to_s.strip)
      report.warnings << "unidade \"#{unit_name}\" não encontrada ou inativa (bairro #{neighborhood_name})" unless unit
      unit&.id
    end
    private_class_method :load_entry, :active_unit_id
  end
end

# Lista Nacional de Notificação Compulsória versionada, no banco de plataforma
# (módulo 25; ADR 0043). `current` escolhe a versão vigente por data; `validate`
# é a regra única de uma lista de doenças (plataforma aqui; as locais da cidade
# usam a mesma com LOCAL_CODE); `Load` e `Publish` gravam.
module Surveillance
  module DiseaseList
    LOCK_KEY = Zlib.crc32("notifiable_disease_versions")
    ORDINANCE_MAX = 200
    NOTES_MAX = 500
    DISEASE_NOTES_MAX = 300
    SINAN_FORM_MAX = 60
    REPEAT_RANGE = (1..36_500)

    module_function

    # Maior `version` com effective_from <= today; nil antes da primeira vigência.
    def current(today:)
      NotifiableDiseaseVersion.where(effective_from: ..today).order(version: :desc).first
    end

    # A última versão publicada (agendada ou em vigor), ou nil.
    def latest = NotifiableDiseaseVersion.order(version: :desc).first

    # -> Result.ok | Result.fail(:invalid_list, details: { path: "diseases.3.cid10.0" }).
    # Primeira recusa vence: doença a doença, campo a campo.
    # `require_sources: false` é da doença local, que não tem fontes (contrato §2).
    def validate(diseases, code_rule: Catalog::PLATFORM_CODE, require_sources: true)
      return refuse("diseases") unless diseases.is_a?(Array) && diseases.any?

      codes = {}
      cid_owners = [] # [código CID-10, índice da doença]
      ciap = {}
      diseases.each_with_index do |raw, i|
        return refuse("diseases.#{i}") unless raw.is_a?(Hash)

        d = raw.stringify_keys
        path = field_error(d, code_rule, require_sources)
        return refuse("diseases.#{i}.#{path}") if path

        return refuse("diseases.#{i}.code") if codes.key?(d["code"])

        codes[d["code"]] = i
        d["cid10"].each_with_index do |c, j|
          return refuse("diseases.#{i}.cid10.#{j}") if cid_owners.any? { |(o, k)| k != i && (c.start_with?(o) || o.start_with?(c)) }
        end
        d["cid10"].each { |c| cid_owners << [ c, i ] }
        d["ciap2"].each_with_index do |c, j|
          return refuse("diseases.#{i}.ciap2.#{j}") if ciap.key?(c)

          ciap[c] = i
        end
      end
      Result.ok
    end

    # Caminho (relativo à doença) do primeiro campo inválido, ou nil.
    def field_error(d, code_rule, require_sources = true)
      return "code" unless d["code"].is_a?(String) && code_rule.match?(d["code"])
      return "name" unless d["name"].is_a?(String) && d["name"].strip == d["name"] && d["name"].length.between?(1, Catalog::NAME_MAX)
      return "deadline" unless Catalog::DEADLINES.key?(d["deadline"])

      %w[cid10 ciap2].each do |field|
        pattern = field == "cid10" ? Catalog::CID10 : Catalog::CIAP2
        list = d[field]
        return field unless list.is_a?(Array)

        bad = list.index { |c| !(c.is_a?(String) && pattern.match?(c)) }
        return "#{field}.#{bad}" if bad

        dup = list.each_with_index.find { |c, j| list.index(c) != j }
        return "#{field}.#{dup[1]}" if dup
      end
      return "repeat_after_days" unless d["repeat_after_days"].is_a?(Integer) && REPEAT_RANGE.cover?(d["repeat_after_days"])
      return "sinan_form" unless d["sinan_form"].nil? || (d["sinan_form"].is_a?(String) && d["sinan_form"].length.between?(1, SINAN_FORM_MAX))
      return "notes" unless d["notes"].nil? || (d["notes"].is_a?(String) && d["notes"].length <= DISEASE_NOTES_MAX)

      return nil unless require_sources

      sources = d["sources"]
      "sources" unless sources.is_a?(Hash) && sources.any? && sources.values.all? { |v| v.is_a?(String) }
    end

    def refuse(path) = Result.fail(:invalid_list, details: { path: path })

    # Grava a versão e suas doenças (já validadas). Chamar dentro de with_lock.
    def create_version!(version:, ordinance:, effective_from:, diseases:, notes: nil, sources: nil, maintainer_id: nil)
      record = NotifiableDiseaseVersion.create!(version: version, ordinance: ordinance, effective_from: effective_from, notes: notes,
                                                sources: sources, published_by_maintainer_id: maintainer_id, created_at: Time.current)
      diseases.each do |raw|
        d = raw.stringify_keys
        record.diseases.create!(d.slice("code", "name", "deadline", "cid10", "ciap2", "repeat_after_days", "sinan_form", "notes", "sources"))
      end
      record
    end

    # Transação na plataforma serializada pelo lock consultivo da lista.
    def with_lock
      PlatformRecord.transaction do
        PlatformRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
        yield
      end
    end
  end
end

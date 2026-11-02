# Esqueleto dos campos 1..1 do RIA-R (Portaria Conjunta SAES/SVSA/SEIDIGI
# 25/2023, quadro Rotina; pesquisa §1). `problems(bundle)` devolve os CAMINHOS
# ausentes (nunca valores: o Bundle é dado sensível). Opcionais: lote e
# fabricante (o código do fabricante pode ser nulo no catálogo, V19, gate de
# homologação), país de origem, hanseníase e pesquisa clínica. Na transcrição a
# caderneta não traz via, local nem grupo: esses três só valem na aplicação.
module Rnds
  module Skeleton
    COMPOSITION = %w[status type date subject.identifier.value author custodian.identifier.value section].freeze
    IMMUNIZATION = %w[
      status vaccineCode.coding.0.system vaccineCode.coding.0.code subject.identifier.value occurrenceDateTime recorded primarySource
      performer.0.actor.identifier.value performer.1.actor.identifier.value
    ].freeze
    APPLICATION_ONLY = %w[route.coding.0.code site.coding.0.code].freeze
    EXTENSIONS = %i[strategy maternal_condition transcription].freeze

    module_function

    def problems(bundle)
      entries = bundle.is_a?(Hash) ? Array(bundle["entry"]) : []
      composition = entries.first.is_a?(Hash) ? entries.first["resource"] : nil
      immunization = entries.last.is_a?(Hash) ? entries.last["resource"] : nil
      problems = []
      problems << "Bundle.type" unless bundle.is_a?(Hash) && bundle["type"] == "document"
      problems << "Bundle.entry.Composition" unless composition.is_a?(Hash) && composition["resourceType"] == "Composition"
      problems << "Bundle.entry.Immunization" unless immunization.is_a?(Hash) && immunization["resourceType"] == "Immunization"
      return problems if problems.any? { |path| path.start_with?("Bundle.entry") }

      transcription = transcription?(immunization)
      problems.concat(missing("Composition", composition, COMPOSITION))
      problems.concat(missing("Immunization", immunization, IMMUNIZATION + (transcription ? [] : APPLICATION_ONLY)))
      problems.concat(extension_problems(immunization, transcription))
      problems << "Composition.section.entry" unless composition.dig("section", 0, "entry", 0, "reference") == entries.last["fullUrl"]
      problems
    end

    def missing(prefix, resource, paths)
      paths.reject { |path| present?(dig(resource, path)) }.map { |path| "#{prefix}.#{path.gsub(/\.\d+/, '')}" }
    end

    def dig(resource, path)
      resource.dig(*path.split(".").map { |key| key.match?(/\A\d+\z/) ? key.to_i : key })
    rescue TypeError
      nil
    end

    def extension_problems(immunization, transcription)
      urls = Array(immunization["extension"]).filter_map { |e| e["url"] if e.is_a?(Hash) }
      keys = transcription ? EXTENSIONS : EXTENSIONS + [ :care_group ]
      keys.reject { |key| urls.include?(Profile.current.extensions.fetch(key)) }.map { |key| "Immunization.extension.#{key}" }
    end

    def transcription?(immunization)
      url = Profile.current.extensions.fetch(:transcription)
      Array(immunization["extension"]).any? { |e| e.is_a?(Hash) && e["url"] == url && e["valueBoolean"] == true }
    end

    def present?(value) = !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
    private_class_method :missing, :dig, :extension_problems, :transcription?, :present?
  end
end

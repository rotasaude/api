# Importação das listas da Anvisa (ADR 0033; contrato §8 importAnvisaLists):
# os arquivos versionados em config/medications/anvisa (transcritos da fonte
# oficial, com SOURCES.yml dizendo de onde e quantos). A release nasce
# `importing` FORA da transação (a falha fica registrada); substâncias,
# ativação, marcas do catálogo e auditoria numa transação só.
require "csv"

module Medications
  module AnvisaImport
    DIR = Rails.root.join("config/medications/anvisa")
    LISTS = %w[A1 A2 A3 B1 B2 C1 C2 C3 C4 C5].freeze
    class Invalid < StandardError; end

    module_function

    def call(by:, dir: DIR)
      dir = Pathname(dir)
      sources, antimicrobials, controlled = read(dir)
      ReleaseLifecycle.fail_stale!(AnvisaListRelease)
      release = begin
        AnvisaListRelease.create!(imported_by: by.to_s.first(80), imported_at: Time.current, status: "importing",
                                  source_sha256: sha256(dir), sources: sources)
      rescue ActiveRecord::RecordNotUnique
        return Result.fail(:import_in_progress)
      end
      PlatformRecord.transaction(requires_new: true) do
        rows = antimicrobials.map { |name| { release_id: release.id, kind: "antimicrobial", substance: name, substance_key: Substances.key(name), controlled_list: nil } } +
               controlled.map { |name, list| { release_id: release.id, kind: "controlled", substance: name, substance_key: Substances.key(name), controlled_list: list } }
        rows.each_slice(1_000) { |slice| AnvisaListSubstance.insert_all!(slice) }
        AnvisaListRelease.active.where.not(id: release.id).lock.each { |old| old.update!(status: "superseded") }
        release.update!(status: "active", activated_at: Time.current, antimicrobials_count: antimicrobials.size,
                        controlled_count: controlled.size)
        Substances.apply_to_catalog!(Substances.matcher(release))
        Platform.audit("anvisa_lists.imported", release_id: release.id, antimicrobials: antimicrobials.size,
                                                controlled: controlled.size)
      end
      Result.ok(release: release.reload, antimicrobials: antimicrobials.size, controlled: controlled.size)
    rescue Invalid, Errno::ENOENT, CSV::MalformedCSVError, Psych::SyntaxError => e
      Result.fail(:invalid_file, message: e.message.truncate(300))
    rescue StandardError => e
      ReleaseLifecycle.mark_failed(release)
      Result.fail(:import_failed, message: e.class.name)
    end

    def read(dir)
      sources = YAML.safe_load_file(dir.join("SOURCES.yml"))
      antimicrobials = CSV.read(dir.join("antimicrobials.csv"), headers: true, encoding: "UTF-8").map { |row| row.fetch("substance").to_s.strip }
      controlled = CSV.read(dir.join("controlled.csv"), headers: true, encoding: "UTF-8").map { |row| [ row.fetch("substance").to_s.strip, row.fetch("list").to_s.strip ] }
      raise Invalid, "antimicrobials: contagem #{antimicrobials.size} ≠ SOURCES #{sources.dig('antimicrobials', 'count')}" if antimicrobials.size != sources.dig("antimicrobials", "count")

      counts = controlled.group_by(&:last).transform_values(&:size)
      raise Invalid, "controlled: contagens #{counts} ≠ SOURCES" if counts != sources.dig("controlled", "counts").to_h.transform_keys(&:to_s)
      raise Invalid, "controlled: lista fora de A1–C5" if (counts.keys - LISTS).any?
      raise Invalid, "nome vazio" if (antimicrobials + controlled.map(&:first)).any?(&:blank?)

      [ sources, antimicrobials, controlled ]
    end

    def sha256(dir) = Digest::SHA256.hexdigest(%w[SOURCES.yml antimicrobials.csv controlled.csv].map { |name| File.binread(dir.join(name)) }.join)
    private_class_method :read, :sha256
  end
end

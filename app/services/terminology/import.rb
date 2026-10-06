# app/services/terminology/import.rb
# Importação de terminologia nacional (ADR 0028; spec 2026-10-05 §4). A release
# nasce `importing` FORA da transação (para a falha ficar registrada); os
# códigos e a ativação entram numa transação só (savepoint), com a auditoria
# — tudo no banco de plataforma. Falha → `failed`, e nada ativo muda.
# Reasons: :unknown_kind, :invalid_version, :file_not_found, :invalid_file.
module Terminology
  module Import
    class Invalid < StandardError; end

    BATCH = 1_000
    VERSION = { "sigtap" => /\A\d{4}(0[1-9]|1[0-2])\z/ }.freeze
    DEFAULT_VERSION = /\A[0-9A-Za-z][0-9A-Za-z.-]{0,19}\z/

    module_function

    def readers = { "cid10" => Cid10Reader, "ciap2" => Ciap2Reader, "sigtap" => SigtapReader }

    def call(kind:, version:, path:, by: "terminology:import")
      reader = readers[kind.to_s]
      return Result.fail(:unknown_kind) unless reader
      return Result.fail(:invalid_version) unless version.to_s.match?(VERSION.fetch(kind.to_s, DEFAULT_VERSION))

      OfficialArchive.open(path) { |archive| import(reader, archive, kind.to_s, version.to_s, by) }
    rescue OfficialArchive::NotFound => e
      Result.fail(:file_not_found, message: e.message)
    end

    def import(reader, archive, kind, version, by)
      release = TerminologyRelease.create!(kind: kind, version: version, source_sha256: archive.sha256,
                                           imported_by: by, imported_at: Time.current, status: "importing")
      counts = PlatformRecord.transaction(requires_new: true) do
        written = reader.new(archive).write(release)
        activate!(release)
        Platform.audit("terminology.release_activated", kind: kind, version: version)
        written
      end
      Result.ok(release: release.reload, counts: counts)
    rescue Invalid, OfficialArchive::NotFound, ActiveRecord::ActiveRecordError, CSV::MalformedCSVError => e
      release&.update!(status: "failed")
      Result.fail(:invalid_file, message: e.message.truncate(300))
    end

    # CID-10 e CIAP-2: uma ativa por kind. SIGTAP: uma ativa por competência (a
    # republicação da mesma competência substitui a anterior).
    def activate!(release)
      previous = TerminologyRelease.active.where(kind: release.kind).where.not(id: release.id)
      previous = previous.where(version: release.version) if release.kind == "sigtap"
      previous.lock.each { |old| old.update!(status: "superseded") }
      release.update!(status: "active", activated_at: Time.current)
    end

    def insert(model, rows)
      rows.each_slice(BATCH) { |slice| model.insert_all!(slice) }
      rows.size
    end
  end
end

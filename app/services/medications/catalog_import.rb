# app/services/medications/catalog_import.rb
# Importação do CATMAT classe 6505 (ADR 0033; spec §3; contrato §8
# importMedicationCatalog). A release nasce `importing` FORA da transação (a
# falha fica registrada); a fonte é lida INTEIRA antes de tocar o catálogo
# (Review Focus 1); a diferença (entrou, mudou, saiu), as marcas Anvisa, a
# ativação e a auditoria entram numa transação só. Item estável por código:
# `changed` = descrição diferente (ou volta de `removed`); `removed` = sumiu
# da fonte (nunca apagado). Fonte que encolhe para menos da metade do ativo
# é recusada (`suspicious_drop`): um catálogo some por erro da fonte, não por
# decisão do Ministério.
module Medications
  module CatalogImport
    MIN_SHARE = 0.5
    class SuspiciousDrop < StandardError; end
    UPDATABLE = %i[pdm_code source_description source_updated_at active_ingredient strength dosage_form unit parse_status
                   review_reason hidden antimicrobial controlled controlled_list status search_text last_release_id
                   updated_at].freeze

    module_function

    def call(by:, client: Catmat::Client.new, now: Time.current)
      matcher = Substances.matcher
      # A importação que morreu no meio (processo derrubado) não trava a próxima.
      ReleaseLifecycle.fail_stale!(MedicationCatalogRelease)
      release = begin
        MedicationCatalogRelease.create!(source: "catmat_6505", imported_by: by.to_s.first(80), imported_at: now,
                                         status: "importing")
      rescue ActiveRecord::RecordNotUnique
        return Result.fail(:import_in_progress)
      end
      rows = client.fetch_all
      active = MedicationCatalogItem.where(status: "active").count
      raise SuspiciousDrop, "lidos #{rows.size} de #{active} ativos" if active.positive? && rows.size < active * MIN_SHARE

      counts = PlatformRecord.transaction(requires_new: true) { apply!(release, rows, matcher, now) }
      Result.ok(release: release.reload, **counts)
    rescue Catmat::Client::Unavailable => e
      failed(release, :source_unavailable, e)
    rescue Catmat::Client::Incomplete => e
      failed(release, :incomplete_source, e)
    rescue SuspiciousDrop => e
      failed(release, :suspicious_drop, e)
    rescue StandardError => e
      failed(release, :import_failed, e, message: e.class.name)
    end

    def apply!(release, rows, matcher, now)
      existing = MedicationCatalogItem.lock.pluck(:catmat_code, :source_description, :status).to_h { |code, *rest| [ code, rest ] }
      added = changed = 0
      records = rows.map do |row|
        parsed = Catmat::DescriptionParser.call(row.pdm_name, row.description)
        flags = matcher.flags_for(parsed.active_ingredient.split(" + "))
        description = row.description.strip
        before = existing[row.catmat_code]
        if before.nil? then added += 1
        elsif before != [ description, "active" ] then changed += 1
        end
        { catmat_code: row.catmat_code, pdm_code: row.pdm_code, source_description: description, source_updated_at: row.updated_at,
          active_ingredient: parsed.active_ingredient, strength: parsed.strength, dosage_form: parsed.dosage_form, unit: parsed.unit,
          parse_status: parsed.parse_status, review_reason: parsed.review_reason, hidden: !parsed.ok?,
          antimicrobial: flags.antimicrobial, controlled: flags.controlled, controlled_list: flags.controlled_list,
          status: "active", search_text: search_text(parsed, description), first_release_id: release.id,
          last_release_id: release.id, created_at: now, updated_at: now }
      end
      records.each_slice(1_000) { |slice| MedicationCatalogItem.upsert_all(slice, unique_by: :catmat_code, update_only: UPDATABLE, record_timestamps: false) }
      seen = rows.map(&:catmat_code)
      gone = MedicationCatalogItem.where(status: "active").where.not(catmat_code: seen)
      removed = gone.update_all(status: "removed", last_release_id: release.id, updated_at: now)
      MedicationCatalogRelease.active.where.not(id: release.id).lock.each { |old| old.update!(status: "superseded") }
      release.update!(status: "active", activated_at: now, items_count: rows.size,
                      hidden_count: MedicationCatalogItem.where(status: "active", hidden: true).count,
                      added_count: added, changed_count: changed, removed_count: removed)
      Platform.audit("medication_catalog.imported", release_id: release.id, added: added, changed: changed,
                                                    removed: removed)
      { added: added, changed: changed, removed: removed }
    end

    def search_text(parsed, description)
      I18n.transliterate([ parsed.active_ingredient, parsed.strength, parsed.dosage_form, description ].compact.join(" ")).upcase.squish
    end

    # Nunca mascara o erro original; a mensagem não leva corpo de resposta.
    def failed(release, reason, error, message: error.message)
      ReleaseLifecycle.mark_failed(release)
      Result.fail(reason, message: message.to_s.truncate(300))
    end
    private_class_method :apply!, :failed
  end
end

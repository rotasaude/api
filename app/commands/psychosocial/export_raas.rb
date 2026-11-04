# Remessa RAAS do mês de um CAPS (ADR 0049; contrato §6, P14, P15, P37; plano,
# Desvios 8 e 9). Quem chama confere o papel (coordenação lotada ou
# faturista) e o step-up.
#
# Sem layout registrado para `layout_version` (raas.yml; null até o gate) →
# 422 raas_layout_unavailable, nada lido nem gravado. Numa transação: trava a
# linha do CAPS (FOR UPDATE, ruling: serializa com CancelAction, que confere a
# exportação sob FOR SHARE, e com Close/ReopenMonth) e só então lê: sem
# fechamento ativo → 409 month_open; já exportado → 409 already_exported (o
# índice único (health_unit_id, month), casado pelo nome, cobre a corrida).
# A competência de apresentação é a do 22 (Billing::Periods.assign!, Desvio 8).
# Entram os registros `closed` da janela com ação RAAS no mês (RaasRecords;
# P14: os sem ação ficam `closed`, nunca `exported`). O arquivo é gravado em
# Base64 cifrado com o SHA-256 dos bytes; os registros exportados ganham o id da
# remessa e `exported` (o trigger os congela). Publica
# `psychosocial.raas_exported` só com o `raas_export_id`.
module Psychosocial
  module ExportRaas
    UNIQUE_INDEX = "idx_psychosocial_raas_exports_month".freeze

    module_function

    # month: dia 1º. -> Result.ok(export:) | fail(:raas_layout_unavailable | :month_open | :already_exported)
    def call(unit:, month:, by:, now: Time.current)
      version = Raas.config["layout_version"]
      return Result.fail(:raas_layout_unavailable) unless RaasFile.available?(version)

      ApplicationRecord.transaction(requires_new: true) do
        unit = HealthUnit.lock("FOR UPDATE").find(unit.id)
        next Result.fail(:month_open) unless MonthlyRecords.closed?(unit.id, month)
        next Result.fail(:already_exported) if MonthlyRecords.exported?(unit.id, month)

        period, = Billing::Periods.assign!(Billing::Establishment.for_unit(unit), month.strftime("%Y%m"))
        entries = RaasRecords.for(unit: unit, month: month, status: "closed", lock: true)
        header = { cnes: unit.cnes, competence: period.competence, month: month.strftime("%Y-%m"), unit_name: unit.name }
        bytes = RaasFile.build(version: version, header: header, records: entries.map { |entry| RaasRecords.file_record(entry) }).b

        export = PsychosocialRaasExport.create!(health_unit: unit, month: month, competence: period.competence, billing_period: period,
                                                layout_version: version, file_data: Base64.strict_encode64(bytes),
                                                sha256: Digest::SHA256.hexdigest(bytes), records_count: entries.size,
                                                created_by_user: by, created_at: now)
        entries.each { |entry| entry.record.update!(status: "exported", psychosocial_raas_export: export) }
        DomainEvents.publish("psychosocial.raas_exported", raas_export_id: export.id)
        Result.ok(export: export)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(UNIQUE_INDEX)

      Result.fail(:already_exported)
    end
  end
end

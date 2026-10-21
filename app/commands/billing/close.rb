# Fechamento da competência (ADR 0039; spec §5.4; contrato §5). Ordem:
# configuração e estabelecimento (UBS nunca gera BPA) fora da transação;
# trava a competência FOR UPDATE (quem grava espera, e depois cai na
# competência seguinte); trava os procedimentos por id; recalcula a crítica
# com o cadastro do momento (grava); sem faturável → nothing_to_export (a
# crítica atualizada fica); gera o arquivo (cifrado), liga os procedimentos à
# versão (e desliga da versão anterior o que não entrou nesta), fecha. Mais
# de 999 folhas: too_many_sheets, nada gravado.
module Billing
  module Close
    module_function

    def call(period:, by:, now: Time.current)
      settings = BillingSetting.current
      return Result.fail(:settings_missing) unless settings

      establishment = Establishment.of(BillingPeriod.find(period.id)) # cadastro de agora, nunca a associação em cache
      return Result.fail(:establishment_is_aps) if establishment.aps?

      ApplicationRecord.transaction do
        period.lock!
        next Result.fail(:invalid_transition, details: { status: period.status }) unless period.status == "open"

        procedures = PerformedProcedure.recorded.where(billing_period_id: period.id).order(:id).lock
                                       .includes(:patient, professional_user: :professional).to_a
        cache = SigtapCache.new # SIGTAP lida uma vez por release e código sob a trava (I2)
        procedures.each { |procedure| Recalculate.call(procedure, establishment: establishment, cache: cache) }
        billable = procedures.select(&:billable)
        next Result.fail(:nothing_to_export) if billable.empty?

        built = Lines.build(period: period, establishment: establishment, procedures: billable, settings: settings)
        export = BillingExport.create!(billing_period: period, version: period.version + 1, cnes: establishment.cnes, competence: period.competence,
                                       file: built.bytes.dup.force_encoding(Encoding::UTF_8), sha256: Digest::SHA256.hexdigest(built.bytes),
                                       lines_bpa_c: built.lines_bpa_c, lines_bpa_i: built.lines_bpa_i, sheets: built.sheets,
                                       control_field: built.control, generated_by_user: by, generated_at: now)
        PerformedProcedure.where(id: billable.map(&:id)).update_all(billing_export_id: export.id, updated_at: now)
        # billing_export_id = entrou no arquivo VIGENTE: quem estava numa versão
        # anterior e não está nesta perde a ligação (ruling, fix round 1).
        PerformedProcedure.where(billing_period_id: period.id).where.not(billing_export_id: [ nil, export.id ])
                          .update_all(billing_export_id: nil, updated_at: now)
        period.update!(status: "closed", version: export.version, closed_at: now, closed_by_user: by)
        DomainEvents.publish("billing_export.generated", billing_export_id: export.id, billing_period_id: period.id)
        DomainEvents.publish("billing_period.closed", billing_period_id: period.id, version: export.version)
        Result.ok(period: period, export: export)
      end
    rescue BpaFile::TooManySheets
      Result.fail(:too_many_sheets)
    end
  end
end

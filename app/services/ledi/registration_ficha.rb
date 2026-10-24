# Comportamento comum das fichas de cadastro (módulo 24a, ADR 0042; plano,
# Desvios 4, 6 e 7), estendido por Ledi::IndividualRegistrationFicha e
# Ledi::HouseholdRegistrationFicha (cada um define SOURCE_TYPE, LEDI_TABLE, PROFILE_FIELDS,
# version_class, sibling_ids(version), values(version) e ficha_class).
# Mesmo contrato do Ledi::ConsultationFicha, sem refresh!/correção: a fonte é
# uma versão imutável, que nunca muda depois de gravada.
#   - Uma ficha por versão, só com a exportação utilizável; quem grava chama
#     generate DENTRO da transação da gravação (Ledi::Enqueue tem savepoint).
#   - Cabeçalho = quem gravou a versão (CNS, CBO do vínculo na equipe), INE da
#     equipe, CNES da unidade da equipe, instante da versão.
#   - Originadora (Desvio 6): a ficha mais antiga do mesmo cadastro/domicílio
#     (qualquer versão) que não está rejected, failed nem correction_pending; sem
#     nenhuma, a ficha sai como cadastro novo (uuidFichaOriginadora = uuid).
#     Reenvio de recusada regera da versão (regenerate): ficha nova recusada →
#     uuid novo e originadora = ele; a atualização seguinte aponta a nova.
#   - Sem identificação: "não gerada" (LediGenerationFailure) com motivos de
#     lista fechada; nunca CPF inventado.
module Ledi
  module RegistrationFicha
    AlreadyResolved = Ledi::ScreeningFicha::AlreadyResolved
    # failed: a fila desistiu, o PEC nunca recebeu — não pode ser originadora.
    NOT_ORIGINATING = %w[rejected failed correction_pending].freeze

    def exportable?(city) = Ledi::ScreeningFicha.exportable?(city)

    # :enqueued | :failed | :unusable | :exists. Com a exportação ligada
    # (Enqueue.accepting?) e o perfil da cidade incompleto, a exportação não é
    # utilizável (o ledi_export exige o IBGE), mas a ficha vira "não gerada"
    # (city_profile_incomplete, L20) em vez de sumir: gerar de novo resolve.
    def generate(version, city: Current.city)
      return :unusable unless exportable?(city) || (Ledi::Enqueue.accepting?(city) && profile_incomplete?)
      return :exists if LediOutboxEntry.exists?(source_type: self::SOURCE_TYPE, source_id: version.id)

      ficha, reasons = build(version)
      return record_failure!(version, reasons) if reasons.any?

      resolve_failure!(version)
      Ledi::Enqueue.call(ficha, city: city) ? :enqueued : :unusable
    end

    # [ficha, []] ou [nil, motivos].
    def build(version)
      unit = version.team.health_unit
      professional = Professional.find(version.saved_by_professional_id)
      reasons = []
      reasons << "unit_without_cnes" if unit.cnes.blank?
      reasons << "professional_without_cns" unless Professionals::Cns.valid?(professional.cns)
      # Defesa: o TerritoryRegistry::Access já recusa a gravação (403 cbo_not_allowed).
      reasons << "cbo_not_in_ledi_table" unless TerritoryRegistry::Access.registrar_cbo?(version.saved_cbo, ficha: self::LEDI_TABLE)
      # Contrato §14 L20: o IBGE (cabeçalho, endereço) e, na domiciliar, a UF
      # (numeroDneUf) vêm do perfil; sem eles nunca chega ao Ledi::Transport.
      reasons << "city_profile_incomplete" if profile_incomplete?
      values, more = values(version)
      reasons.concat(more)
      return [ nil, reasons ] if reasons.any?

      header = Ledi::Fichas::RegistrationHeader.new(
        cnes: unit.cnes, ine: version.team.ine, professional_cns: professional.cns, cbo: version.saved_cbo,
        saved_at: version.created_at, ibge_code: CityProfile.current&.ibge_code
      )
      [ ficha_class.new(header: header, values: values, originating_uuid: originating_uuid(version), source_id: version.id), [] ]
    end

    # PROFILE_FIELDS de quem estende: os campos do CityProfile que a ficha usa.
    def profile_incomplete?
      profile = CityProfile.current
      return true unless profile && profile.ibge_code.present?

      self::PROFILE_FIELDS.include?(:uf) && !TerritoryRegistry::Catalog::UF_TO_DNE.key?(profile.uf)
    end

    def originating_uuid(version)
      LediOutboxEntry.where(source_type: self::SOURCE_TYPE, source_id: sibling_ids(version))
                     .where.not(status: NOT_ORIGINATING).order(:created_at, :id).pick(:uuid)
    end

    def record_failure!(version, reasons)
      failure = LediGenerationFailure.unresolved.find_by(source_type: self::SOURCE_TYPE, source_id: version.id)
      if failure
        failure.update!(reason_codes: reasons) unless failure.reason_codes == reasons
      else
        failure = ApplicationRecord.transaction(requires_new: true) do
          LediGenerationFailure.create!(source_type: self::SOURCE_TYPE, source_id: version.id, reason_codes: reasons)
        end
        DomainEvents.publish("ledi.generation_failed", failure_id: failure.id, source_type: self::SOURCE_TYPE,
                                                       source_id: version.id)
      end
      :failed
    rescue ActiveRecord::RecordNotUnique
      :failed
    end

    def resolve_failure!(version)
      LediGenerationFailure.unresolved.where(source_type: self::SOURCE_TYPE, source_id: version.id)
                           .update_all(resolved_at: Time.current, updated_at: Time.current)
    end

    # "Gerar de novo" (contratos §6 do 18), como Ledi::ScreeningFicha.retry!.
    def retry!(failure, by:)
      failure.with_lock do
        raise AlreadyResolved if failure.resolved?

        version = version_class.find_by(id: failure.source_id)
        outcome = version ? generate(version) : :skipped
        resolve_failure!(version) if outcome == :exists
        DomainEvents.publish("ledi.generation_retried", failure_id: failure.id, source_type: failure.source_type,
                                                        source_id: failure.source_id)
      end
      failure.reload
    end

    # "Reenviar" recusada: regera da versão (uuid novo, replaces_outbox_id). A
    # recusada deixa de ser originadora; a nova ficha aponta a mais antiga
    # restante, ou é cadastro novo com originadora = o próprio uuid novo.
    def regenerate(entry, by:, city: Current.city)
      ApplicationRecord.transaction do
        entry.lock!
        next [ :not_rejected, nil ] unless entry.status == "rejected"
        next [ :not_rejected, nil ] if LediOutboxEntry.exists?(replaces_outbox_id: entry.id)
        next [ :export_unusable, nil ] unless exportable?(city)

        version = version_class.find(entry.source_id)
        ficha, reasons = build(version)
        if reasons.any?
          record_failure!(version, reasons)
          next [ :generation_failed, nil ]
        end
        fresh = Ledi::Enqueue.call(ficha, city: city, replaces: entry)
        next [ :export_unusable, nil ] unless fresh

        resolve_failure!(version)
        DomainEvents.publish("ledi.ficha_resent", outbox_id: entry.id, user_id: by.id)
        [ :ok, fresh ]
      end
    end
  end
end

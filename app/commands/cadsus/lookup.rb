# Consulta ao CADSUS no balcão (ADR 0028; spec 2026-10-05 §7; contratos §5.4;
# desvios 6 e 8). Exige o interruptor utilizável. Compara nascimento e sexo em
# memória com o perfil do cidadão (ADR 0027; null sem perfil) e guarda só o CNS
# como PENDENTE desta sessão — quem o efetiva é Citizens::Verify com
# cadsus_confirmed. Credencial recusada marca a credencial (o interruptor deixa
# de ser utilizável e a tela de Integrações mostra). Banco da cidade
# inalcançável também vira indisponível. Reasons: :cadsus_unavailable.
module Cadsus
  module Lookup
    WINDOW = 10.minutes

    module_function

    def call(citizen:, by:, session:, city:)
      return Result.fail(:cadsus_unavailable) unless Platform::Features.usable?(city, "cadsus_lookup")

      record = Client.for(city).lookup(citizen.cpf)
      cns = record&.cns
      ApplicationRecord.transaction do
        citizen.update!(cadsus_pending_cns: cns, cadsus_pending_session_id: cns && session.id,
                        cadsus_pending_at: cns && Time.current)
        DomainEvents.publish("citizen.cadsus_looked_up", citizen_id: citizen.id, user_id: by.id, found: !record.nil?)
      end
      Result.ok(found: !record.nil?, cns_masked: Professionals::Cns.mask(cns),
                birth_date_matches: compare(citizen.birth_date, record&.birth_date),
                sex_matches: compare(citizen.sex, record&.sex))
    rescue Cadsus::Unauthorized
      mark_refused!(city)
      Result.fail(:cadsus_unavailable)
    rescue Cadsus::Error, *Maintenance::CityConnectionErrors::CLASSES, ActiveRecord::StatementInvalid
      Result.fail(:cadsus_unavailable)
    end

    def compare(declared, found)
      return nil if declared.blank? || found.blank?

      declared.to_s == found.to_s
    end

    def mark_refused!(city)
      CityConnection.with(city) do
        IntegrationCredential.where(kind: "cadsus").update_all(
          last_check_at: Time.current, last_check_status: "unauthorized", last_check_message: "O CADSUS recusou a credencial"
        )
      end
    rescue *Maintenance::CityConnectionErrors::CLASSES, ActiveRecord::StatementInvalid
      nil
    end
  end
end

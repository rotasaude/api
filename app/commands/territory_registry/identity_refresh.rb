# Validação no posto depois do cadastro (contrato §14 L4, L24): quando
# Patients::Resolve.refresh! troca nome, nome social, mãe, nascimento ou sexo
# de um paciente com cadastro individual ativo, os dados validados já estão
# no PACIENTE; o cadastro só ganha a marca identity_changed_at (com o
# interruptor ligado ou não). L24: nunca versão nem ficha em nome de quem
# não agiu — a próxima gravação de quem cadastra leva a identidade validada
# (SaveRegistration lê a identidade atual do paciente), em nome dela; até
# lá, identity_review_pending (IndividualRegistration) avisa a equipe.
#
# Roda na transação de quem chamou, com o paciente já travado (Resolve e
# AddCpf travam): trava o cadastro depois (ordem do Desvio 12).
# SaveRegistration suspende a renovação (`suppressing`) enquanto grava: a
# versão dela já leva a identidade validada; só anota quem mudou.
module TerritoryRegistry
  module IdentityRefresh
    WATCHED = %w[full_name social_name mother_name birth_date sex].freeze
    SUPPRESSED = :territory_registry_identity_refresh_suppressed

    module_function

    # :marked | :none
    def call(patient)
      collector = ActiveSupport::IsolatedExecutionState[SUPPRESSED]
      if collector
        collector << patient.id
        return :none
      end

      registration = IndividualRegistration.active_registrations.find_by(patient_id: patient.id)
      return :none unless registration

      registration.lock!
      latest = registration.latest_version
      changed = Identity.changed_fields(latest.identity, Identity.snapshot(patient)) & WATCHED
      return :none if changed.empty?

      registration.update!(identity_changed_at: Time.current)
      :marked
    end

    # Dentro do bloco, call só anota em `collector` o id do paciente.
    def suppressing(collector)
      previous = ActiveSupport::IsolatedExecutionState[SUPPRESSED]
      ActiveSupport::IsolatedExecutionState[SUPPRESSED] = collector
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[SUPPRESSED] = previous
    end
  end
end

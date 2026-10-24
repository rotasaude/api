# Validação no posto depois do cadastro (contrato §14 L4; plano, Desvio 5):
# quando Patients::Resolve.refresh! troca nome, nome social, mãe, nascimento
# ou sexo de um paciente com cadastro individual ativo, os dados validados
# substituem os digitados — nova versão `identity_refresh` (mesmas seções) e
# a ficha, em nome de quem gravou a versão anterior (o LEDI pede o
# profissional do cadastro; ninguém digitou nada agora) —, e o cadastro
# marca identity_changed_at (a tela mostra o que mudou). Sem o interruptor
# (Gate.enabled?, só a plataforma) só marca.
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

    # :versioned | :marked | :none
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

      now = Time.current
      unless Gate.enabled?(Current.city)
        registration.update!(identity_changed_at: now)
        return :marked
      end

      SaveRegistration.append!(registration, origin: "identity_refresh", saved_by_user_id: latest.saved_by_user_id,
                                             saved_by_professional_id: latest.saved_by_professional_id, saved_cbo: latest.saved_cbo,
                                             header: { identity_changed_at: now, registered_at: now,
                                                       registered_by_user_id: latest.saved_by_user_id }, at: now)
      :versioned
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

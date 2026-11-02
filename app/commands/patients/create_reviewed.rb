# Paciente digitado na forma do 24a (`new_patient`) com a conferência de
# duplicado (§14 L28 do 24a), extraído da receita externa da farmácia (27a)
# para a sala de vacina (29, §15 V3) criar o recém-nascido sem cadastro pelo
# mesmo caminho: trava consultiva da match_key (a chave é um hash — nunca nome
# nem nascimento no SQL), depois o duplicado (Patients::Duplicates), depois
# Patients::CreateTyped. Dentro da transação de quem chama, a trava dura até o
# fim dela; sem transação de fora, até o fim desta.
module Patients
  module CreateReviewed
    module_function

    # -> Result.ok(patient:) | fail(:duplicate_suspected) |
    #    fail(:cpf_taken | :cns_taken, details: { path: "new_patient.cpf|cns" }) | fail(<recusa do CreateTyped>, details:)
    def call(new_patient:, reviewed:, by:)
      typed = new_patient.to_h.stringify_keys
      result = nil
      # Recusa desfaz este trecho (savepoint): nada do paciente fica gravado.
      ApplicationRecord.transaction(requires_new: true) do
        result = create(typed, reviewed, by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def create(typed, reviewed, by)
      key = typed.values_at("full_name", "birth_date").all?(String) && MatchKey.for(typed["full_name"], typed["birth_date"])
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key(key)})") if key
      return Result.fail(:duplicate_suspected) if !reviewed && duplicate?(typed)

      created = CreateTyped.call(attrs: typed, by: by)
      return created if created.ok?

      path = { cpf_taken: "new_patient.cpf", cns_taken: "new_patient.cns" }[created.reason]
      Result.fail(created.reason, details: path ? { path: path } : created.details)
    end

    # Possível duplicado pela regra da busca (Patients::Duplicates); com CPF
    # digitado, só candidatos sem CPF (outro CPF é outra pessoa; o mesmo é cpf_taken).
    def duplicate?(typed)
      strings = %w[full_name birth_date mother_name cpf].map { |key| typed[key] }
      return false unless strings.all? { |value| value.nil? || value.is_a?(String) }

      Duplicates.call(full_name: strings[0], birth_date: strings[1], mother_name: strings[2], limit: 1,
                      only_without_cpf: strings[3].present?).any?
    end

    def lock_key(key) = Digest::SHA256.hexdigest("patients:match_key:#{key}")[0, 15].to_i(16)
    private_class_method :create, :duplicate?, :lock_key
  end
end

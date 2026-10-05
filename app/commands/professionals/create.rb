# Cria o perfil (ADR 0021): só para usuário ativo com o papel
# health_professional ativo, um por usuário. Quem chama já é municipal_admin.
module Professionals
  class Create
    UNIQUE_REASONS = {
      "index_professionals_on_user_id" => :already_exists,
      "idx_professionals_cns" => :cns_taken,
      "idx_professionals_cpf" => :cpf_taken,
      "idx_professionals_registration" => :registration_taken
    }.freeze

    def self.call(user_id:, attrs:, by:)
      user = User.find_by(id: user_id)
      return Result.fail(:not_found) unless user
      return Result.fail(:user_missing_role) unless user.active? && user.has_role?("health_professional")
      return Result.fail(:already_exists) if Professional.exists?(user_id: user.id)

      professional = Professional.new(attrs.to_h.stringify_keys.slice(*Professional::FIELDS).merge("user" => user))
      unless professional.valid?
        return Result.fail(:invalid, details: { fields: professional.errors.attribute_names.map(&:to_s).sort })
      end

      ApplicationRecord.transaction do
        professional.save!
        DomainEvents.publish("professional.created", professional_id: professional.id, user_id: user.id, by_user_id: by.id)
      end
      Result.ok(professional: professional)
    rescue ActiveRecord::RecordNotUnique => e
      Result.fail(unique_reason(e))
    end

    def self.unique_reason(error)
      UNIQUE_REASONS.find { |index, _| error.message.include?(index) }&.last || :invalid
    end
  end
end

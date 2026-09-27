# Edita o perfil. O admin passa a lista inteira (FIELDS); o próprio
# profissional passa SELF_EDITABLE (emenda ao ADR 0021). Chave fora da lista é
# recusada, não ignorada: a tela precisa saber que o campo não foi gravado.
module Professionals
  class UpdateProfile
    def self.call(professional:, attrs:, by:, allowed: Professional::FIELDS)
      attrs = attrs.to_h.stringify_keys
      extra = attrs.keys - allowed
      return Result.fail(:field_not_editable, details: { fields: extra.sort }) if extra.any?

      professional.assign_attributes(attrs)
      changed = professional.changes.reject { |_, (a, b)| a == b }.keys.sort
      return Result.ok(professional: professional) if changed.empty?

      unless professional.valid?
        fields = professional.errors.attribute_names.map(&:to_s).sort
        professional.restore_attributes
        return Result.fail(:invalid, details: { fields: fields })
      end

      ApplicationRecord.transaction do
        professional.save!
        DomainEvents.publish("professional.profile_updated", professional_id: professional.id, fields: changed,
                                                              by_user_id: by.id)
      end
      Result.ok(professional: professional)
    rescue ActiveRecord::RecordNotUnique => e
      professional.restore_attributes
      Result.fail(Create.unique_reason(e))
    end
  end
end

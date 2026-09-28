# Edita o perfil. O admin passa a lista inteira (FIELDS); o próprio
# profissional passa SELF_EDITABLE (emenda ao ADR 0021). Chave fora da lista é
# recusada, não ignorada: a tela precisa saber que o campo não foi gravado.
#
# FOR UPDATE no profissional antes da checagem de council_in_use e do save
# (D: race do conselho): um OpenLink concorrente (que trava unidade ->
# profissional -> vínculo) espera ou é visto, então a checagem nunca aprova
# uma troca de conselho que um vínculo novo, ainda não visível, já invalida.
# `lock!` recusa registro com mudança pendente, então a trava vem ANTES de
# assign_attributes.
module Professionals
  class UpdateProfile
    def self.call(professional:, attrs:, by:, allowed: Professional::FIELDS)
      attrs = attrs.to_h.stringify_keys
      extra = attrs.keys - allowed
      return Result.fail(:field_not_editable, details: { fields: extra.sort }) if extra.any?

      ApplicationRecord.transaction do
        professional.lock!
        professional.assign_attributes(attrs)
        changed = professional.changes.reject { |_, (a, b)| a == b }.keys.sort
        next Result.ok(professional: professional) if changed.empty?

        unless professional.valid?
          fields = professional.errors.attribute_names.map(&:to_s).sort
          professional.restore_attributes
          next Result.fail(:invalid, details: { fields: fields })
        end

        if changed.include?("council")
          blocking_codes = blocking_cbo_codes(professional)
          if blocking_codes.any?
            professional.restore_attributes
            next Result.fail(:council_in_use, details: { cbo_codes: blocking_codes })
          end
        end

        professional.save!
        DomainEvents.publish("professional.profile_updated", professional_id: professional.id, fields: changed,
                                                              by_user_id: by.id)
        Result.ok(professional: professional)
      end
    rescue ActiveRecord::RecordNotUnique => e
      professional.restore_attributes
      Result.fail(Create.unique_reason(e))
    end

    # D9: trocar de conselho não pode deixar um vínculo ativo cuja ocupação
    # (CBO) exige o conselho antigo. CBO sem conselho exigido (council nil)
    # nunca bloqueia.
    def self.blocking_cbo_codes(professional)
      new_council = professional.council
      professional.links.active.distinct.pluck(:cbo_code).select do |code|
        entry = Cbo.find(code)
        entry&.council && entry.council != new_council
      end.sort
    end
  end
end

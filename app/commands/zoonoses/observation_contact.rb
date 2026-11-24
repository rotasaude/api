# Contato da observação do animal agressor (módulo 35b, ADR 0054; contrato
# §5, §16, Q12, Q26): o nome e o telefone do tutor e o endereço do animal, do
# bloco do animal da ficha do 25 (o `form` cifrado da notificação; ausente →
# nil). A única resposta do 35b com esse contato: nunca em lista, detalhe,
# log ou evento. Para team? (senão missing_role), sem step-up a mais (Q12).
# Grava a trilha `bite_observation.contact_viewed` { bite_observation_id,
# user_id } (Zoonoses::Trail, molde do transmission_block_case.address_viewed,
# Q26); o controlador responde com Cache-Control: no-store.
module Zoonoses
  module ObservationContact
    FIELDS = %w[animal_tutor_name animal_tutor_phone animal_address].freeze

    module_function

    # -> Result.ok(contact: { animal_tutor_name:, animal_tutor_phone:, animal_address: }) | fail(:missing_role)
    def call(observation:, by:)
      return Result.fail(:missing_role) unless Access.team?(by)

      form = observation.disease_notification.form
      form = {} unless form.is_a?(Hash)
      contact = FIELDS.to_h { |key| [ key.to_sym, form[key] ] }
      Trail.observation_contact_viewed!(user: by, observation_id: observation.id)
      Result.ok(contact: contact)
    end
  end
end

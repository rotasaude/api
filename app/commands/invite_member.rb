# Convite de membro para a cidade da conexão corrente. user.invited — que leva o
# e-mail do convidado — vai para o domain_events DA CIDADE, que guarda quem
# acessa os dados dela; nunca para a plataforma (Ruling R18).
class InviteMember
  def self.call(email:, role:, invited_by:, expires_in: 7.days)
    new(email: email, role: role, invited_by: invited_by, expires_in: expires_in).call
  end

  def initialize(email:, role:, invited_by:, expires_in:)
    @email, @role, @invited_by, @expires_in = email, role, invited_by, expires_in
  end

  def call
    # Spec de assinaturas §7: o mantenedor não convida quem aprova protocolo
    # nem quem concede aprovação. ALLOWLIST pelo TIPO de ator (M8, rodada de
    # revisão): um papel de Membership::PRIVILEGED_ROLES só é convidado por um
    # ator cujo actor_kind é "user" — checar o tipo permitido, em vez de
    # enumerar "!= maintainer", não depende de listar todo tipo de ator que
    # já existe ou vier a existir.
    #
    # `invited_by: nil` é o operador de plataforma provisionando o primeiro
    # municipal_admin de uma cidade nova (CityLifecycle::InviteAdmin) — fora
    # desta checagem, como sempre foi: não é um ator da aplicação para
    # responder a pergunta nenhuma de papel, é o próprio provisionamento.
    if Membership::PRIVILEGED_ROLES.include?(@role.to_s) && !@invited_by.nil?
      authorized_actor = @invited_by.respond_to?(:actor_kind) && @invited_by.actor_kind == "user"
      unless authorized_actor
        return Result.fail(:forbidden_for_maintainer,
                           message: "o mantenedor não convida #{@role}: quem aprova protocolo é escolhido pela cidade")
      end
    end

    inv = nil
    ApplicationRecord.transaction do
      inv = Invitation.create!(
        email: @email.downcase,
        role: @role,
        token: SecureRandom.urlsafe_base64(32),
        invited_by: @invited_by,
        expires_at: @expires_in.from_now
      )
      DomainEvents.publish("user.invited", email: @email, role: @role, invitation_id: inv.id)
    end
    Result.ok(invitation: inv)
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(:invalid, message: e.record.errors.full_messages.join(", "))
  end
end

# Aceite de convite — PÚBLICO, o token é a credencial. Roda na cidade do host
# (CityResolution): convite, usuário, identidade e membership moram no banco da
# cidade, e membership.granted vai para o domain_events DELA (Ruling R18),
# nunca para a plataforma.
class AcceptInvitation
  MIN_PASSWORD_LENGTH = 12

  def self.call(token:, password:)
    new(token: token, password: password).call
  end

  def initialize(token:, password:)
    @token, @password = token, password
  end

  def call
    inv = Invitation.find_by(token: @token)
    return Result.fail(:invalid_token, message: "convite inválido") if inv.nil? || inv.accepted_at.present?
    return Result.fail(:expired, message: "este convite venceu; peça um novo") if inv.expired?
    if @password.to_s.length < MIN_PASSWORD_LENGTH
      return Result.fail(:weak_password, message: "a senha precisa de pelo menos #{MIN_PASSWORD_LENGTH} caracteres")
    end
    if User.exists?(email_address: inv.email.downcase)
      return Result.fail(:already_member, message: "este e-mail já tem conta nesta cidade")
    end

    user = nil
    failure = nil
    ApplicationRecord.transaction do
      # Dois aceites do mesmo token ao mesmo tempo: a trava na linha serializa
      # os dois, e o segundo relê o convite já aceito (ou vencido) aqui.
      inv.lock!
      failure = Result.fail(:invalid_token, message: "convite inválido") if inv.accepted_at.present?
      failure ||= Result.fail(:expired, message: "este convite venceu; peça um novo") if inv.expired?
      raise ActiveRecord::Rollback if failure

      user = User.create!(email_address: inv.email, password: @password)
      Identity.create!(user: user, provider: "password", provider_uid: inv.email)
      Membership.create!(
        user: user,
        role: inv.role,
        granted_by: inv.invited_by,
        granted_at: Time.current
      )
      inv.update!(accepted_at: Time.current)
      DomainEvents.publish("membership.granted", user_id: user.id, role: inv.role)
    end
    return failure if failure

    Result.ok(user: user)
  rescue ActiveRecord::RecordNotUnique
    # Outro aceite (outro convite, mesmo e-mail) criou a conta entre a checagem
    # acima e o INSERT: o índice único de e-mail decide, e a transação já voltou.
    Result.fail(:already_member, message: "este e-mail já tem conta nesta cidade")
  end
end

require "rails_helper"

# Quem a tela de manutenção impersona numa cidade. Vive fora do controller pelo
# mesmo motivo do CityInventory: a rota /dev/impersonate só é desenhada em
# development, e a suíte roda em test — nenhum request spec a alcança. A escolha
# do alvo é a parte com regra, então é ela que fica coberta.
#
# A regra que estes exemplos existem para travar: impersonate NÃO é "entrar como
# qualquer um". O alvo é derivado da cidade do host, e só uma conta que de fato
# poderia entrar sozinha é elegível. Conta desativada ou com papel revogado não
# volta a ter acesso por esta porta — senão o atalho de dev vira um jeito de
# ressuscitar acesso que o domínio já tirou.
RSpec.describe DevImpersonation do
  let!(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }

  def target_in(city) = CityConnection.with(city) { described_class.target }

  def user_with(role:, revoked_at: nil, deactivated_at: nil, email:)
    CityConnection.with(city) do
      user = User.create!(email_address: email, password: "senha-de-teste-123",
                          deactivated_at: deactivated_at)
      Membership.create!(user: user, role: role, granted_at: 1.day.ago, revoked_at: revoked_at)
      user
    end
  end

  it "picks the active municipal_admin of the city" do
    user_with(role: "municipal_admin", email: "admin@cidade.demo")

    expect(target_in(city)&.email_address).to eq("admin@cidade.demo")
  end

  # Revogar papel é end-date, não DELETE: a conta continua existindo e continua
  # autenticando por senha, mas sem o papel. Impersonar por aqui devolveria a ela
  # um acesso administrativo que o domínio já retirou.
  it "ignores an account whose municipal_admin role was revoked" do
    user_with(role: "municipal_admin", revoked_at: Time.current, email: "ex@cidade.demo")

    expect(target_in(city)).to be_nil
  end

  # Desativação é end-dating por ADR-0012, e destrói as sessões existentes.
  # Criar uma nova sessão para a conta desativada desfaria exatamente isso.
  it "ignores a deactivated account even with the role intact" do
    user_with(role: "municipal_admin", deactivated_at: Time.current, email: "inativo@cidade.demo")

    expect(target_in(city)).to be_nil
  end

  it "ignores an account whose only role is not municipal_admin" do
    user_with(role: "viewer", email: "viewer@cidade.demo")

    expect(target_in(city)).to be_nil
  end

  # Sem alvo a ação responde 404: a cidade existe, mas não há conta a impersonar.
  # Nil é o contrato que permite isso, em vez de levantar.
  it "returns nil when the city has no one to impersonate" do
    expect(target_in(city)).to be_nil
  end

  it "is deterministic when more than one account qualifies" do
    user_with(role: "municipal_admin", email: "zulma@cidade.demo")
    user_with(role: "municipal_admin", email: "ana@cidade.demo")

    expect(target_in(city)&.email_address).to eq("ana@cidade.demo")
  end

  # O operador é da PLATAFORMA e não pertence a cidade nenhuma: nada de
  # CityConnection aqui. Mesma regra de elegibilidade do lado da cidade — só
  # quem já poderia entrar sozinho — mas com um requisito a mais, porque o
  # login real do console tem um a mais: TOTP inscrito.
  describe ".operator" do
    def operator_with(email:, otp_enabled: true, otp_secret: "JBSWY3DPEHPK3PXP", deactivated_at: nil)
      Operator.create!(email_address: email, password: "senha-de-teste-123",
                       otp_enabled: otp_enabled, otp_secret: otp_secret,
                       deactivated_at: deactivated_at)
    end

    it "picks the active operator with MFA enrolled" do
      operator_with(email: "dev@local")

      expect(described_class.operator&.email_address).to eq("dev@local")
    end

    # Operators::SessionsController#create responde 403 mfa_enrollment_required
    # para operador sem TOTP inscrito: ele NÃO consegue entrar pelo caminho
    # normal. Impersonar um daria acesso que o login real recusa — e o atalho de
    # dev não pode ser mais permissivo que a porta da frente.
    it "ignores an operator without MFA enrolled, whom the real login refuses" do
      operator_with(email: "semtotp@local", otp_enabled: false, otp_secret: nil)

      expect(described_class.operator).to be_nil
    end

    it "ignores a deactivated operator" do
      operator_with(email: "inativo@local", deactivated_at: Time.current)

      expect(described_class.operator).to be_nil
    end

    it "returns nil when there is no operator to impersonate" do
      expect(described_class.operator).to be_nil
    end

    it "is deterministic when more than one operator qualifies" do
      operator_with(email: "zulma@local")
      operator_with(email: "ana@local")

      expect(described_class.operator&.email_address).to eq("ana@local")
    end
  end
end

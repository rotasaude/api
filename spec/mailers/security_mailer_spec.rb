require "rails_helper"

# Aviso de mudança do segundo fator (spec 2026-09-23-authenticator-change-notice
# §4). Renderiza de verdade: view ausente ou layout quebrado tem de ficar
# vermelho aqui, não na primeira entrega em produção.
RSpec.describe SecurityMailer, type: :mailer do
  # 13:30 UTC == 10:30 em America/Sao_Paulo — prova que a view exibe no horário
  # de Brasília, qualquer que seja o offset da string recebida.
  let(:occurred_at) { "2026-09-23T13:30:00Z" }

  def build_mail(kind:)
    described_class.authenticator_changed(
      email_address: "ana@cidade.gov.br", kind: kind, city_name: "Curitiba",
      ip_address: "203.0.113.10", occurred_at: occurred_at
    )
  end

  def bodies(mail) = [ mail.text_part.body.decoded, mail.html_part.body.decoded ]

  it "cadastro: assunto e corpo com cidade, hora de Brasília, IP e o que fazer" do
    mail = build_mail(kind: "enrolled")

    expect(mail.to).to eq([ "ana@cidade.gov.br" ])
    expect(mail.subject).to eq("[rota-saúde] Autenticador cadastrado")
    bodies(mail).each do |body|
      expect(body).to include("Curitiba")
      expect(body).to include("cadastrado")
      expect(body).to include("23/09/2026 10:30")
      expect(body).to include("203.0.113.10")
      expect(body).to include("Se não foi você")
      expect(body).to include("administrador municipal")
    end
  end

  it "troca: assunto próprio e o aviso dos códigos antigos" do
    mail = build_mail(kind: "replaced")

    expect(mail.subject).to eq("[rota-saúde] Autenticador trocado")
    bodies(mail).each do |body|
      expect(body).to include("trocado")
      expect(body).to include("códigos de recuperação anteriores deixaram de valer")
    end
  end

  it "o cadastro NÃO fala de códigos antigos (não havia)" do
    bodies(build_mail(kind: "enrolled")).each do |body|
      expect(body).not_to include("códigos de recuperação anteriores")
    end
  end

  # Defensivo: o mailer recebe só valores simples, e nenhum deles é segredo.
  # Guarda contra alguém acrescentar segredo ou link no futuro.
  it "não leva segredo, código nem link" do
    bodies(build_mail(kind: "replaced")).each do |body|
      expect(body).not_to match(/otpauth|otp_secret/i)
      expect(body).not_to match(/https?:\/\//)
    end
  end

  it "recusa um kind desconhecido em vez de mandar e-mail ambíguo" do
    expect { described_class.authenticator_changed(
      email_address: "ana@cidade.gov.br", kind: "sei-la", city_name: "Curitiba",
      ip_address: "203.0.113.10", occurred_at: occurred_at
    ).subject }.to raise_error(ArgumentError)
  end

  # F3 (final-fix-brief.md): "sua conta na <cidade>" lê mal — falta a palavra
  # "cidade" entre a preposição e o nome próprio.
  it "o corpo usa \"cidade de\" antes do nome da cidade, não \"na <cidade>\" direto" do
    bodies(build_mail(kind: "enrolled")).each do |body|
      expect(body).to include("cidade de Curitiba")
    end
  end

  # F3: no texto puro, linha em branco antes da frase de ação e antes do aviso
  # de códigos antigos — sem linha solta extra deixada pelas tags <% if %>/<% end %>.
  it "o texto puro separa a frase de ação e o aviso de códigos antigos com linha em branco, sem linha solta" do
    mail = build_mail(kind: "replaced")
    text = mail.text_part.body.decoded

    expect(text).to include("203.0.113.10\n\nSe não foi você")
    expect(text).to include("em seu nome.\n\nOs códigos de recuperação anteriores deixaram de valer.\n")
    expect(text).not_to match(/\n{3,}/)
  end

  it "na troca, a frase de ação é a última coisa antes do aviso de códigos antigos" do
    mail = build_mail(kind: "replaced")
    bodies(mail).each do |body|
      ip_idx = body.index("203.0.113.10")
      action_idx = body.index("Se não foi você")
      codes_idx = body.index("códigos de recuperação anteriores")

      expect(ip_idx).to be < action_idx, "IP deve vir antes da frase de ação"
      expect(action_idx).to be < codes_idx, "frase de ação deve vir antes do aviso de códigos"
    end
  end

  describe "recovery_code_used" do
    def build_recovery_mail(remaining:)
      described_class.recovery_code_used(
        email_address: "ana@cidade.gov.br", city_name: "Curitiba",
        ip_address: "203.0.113.10", occurred_at: occurred_at, remaining: remaining
      )
    end

    it "assunto e corpo com cidade, hora de Brasília, IP, frase de ação e contagem" do
      mail = build_recovery_mail(remaining: 9)

      expect(mail.to).to eq([ "ana@cidade.gov.br" ])
      expect(mail.subject).to eq("[rota-saúde] Código de recuperação usado")
      bodies(mail).each do |body|
        expect(body).to include("cidade de Curitiba")
        expect(body).to include("23/09/2026 10:30")
        expect(body).to include("203.0.113.10")
        expect(body).to include("Se não foi você")
        expect(body).to include("Restam 9 códigos de recuperação")
      end
    end

    it "sem nenhum código restante, avisa que só o autenticador aprova" do
      bodies(build_recovery_mail(remaining: 0)).each do |body|
        expect(body).to include("Não resta nenhum código")
        expect(body).to include("só o autenticador")
      end
    end

    it "com códigos restantes, NÃO fala do 'só o autenticador'" do
      bodies(build_recovery_mail(remaining: 9)).each do |body|
        expect(body).not_to include("só o autenticador")
      end
    end

    # F1 (final-fix-brief.md): com um código só restando, é a última chamada
    # antes do "não resta nenhum" — lida por um servidor municipal, que "Restam
    # 1 códigos" atropela.
    it "com só um código restante, usa o singular" do
      bodies(build_recovery_mail(remaining: 1)).each do |body|
        expect(body).to include("Resta 1 código de recuperação")
        expect(body).not_to include("Restam 1")
      end
    end

    it "a frase de ação vem antes da contagem" do
      bodies(build_recovery_mail(remaining: 9)).each do |body|
        expect(body.index("Se não foi você")).to be < body.index("Restam 9")
      end
    end

    it "não leva código, segredo nem link" do
      bodies(build_recovery_mail(remaining: 1)).each do |body|
        expect(body).not_to match(/otpauth|otp_secret/i)
        expect(body).not_to match(/https?:\/\//)
        # Nenhum código de recuperação tem esta forma no corpo: 10 caracteres
        # alfanuméricos minúsculos isolados (Mfa::PendingEnrollment::RECOVERY_LEN
        # — o código de usuário de cidade vem de lá, não de Mfa::Enroll).
        expect(body).not_to match(/\b[a-z0-9]{10}\b/)
      end
    end
  end
end

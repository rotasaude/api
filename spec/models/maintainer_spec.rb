require "rails_helper"

# Spec da API de manutenção §6: identidade própria, separada de Operator, com
# poderes totais — então a força está na autenticação: TOTP obrigatório,
# bloqueio por conta e desativação que mata sessões na hora.
RSpec.describe Maintainer do
  include ActiveSupport::Testing::TimeHelpers

  def build_maintainer(email: "m-#{SecureRandom.hex(3)}@rotasaude.app")
    described_class.create!(email_address: email)
  end

  it "normalizes and refuses a duplicate e-mail, whatever the case" do
    build_maintainer(email: "Alguem@Rotasaude.APP")

    expect(described_class.find_by(email_address: "alguem@rotasaude.app")).to be_present
    expect { build_maintainer(email: "ALGUEM@rotasaude.app") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "is not enrolled until it has a password and a confirmed TOTP" do
    maintainer = build_maintainer
    expect(maintainer.enrolled?).to be(false)

    maintainer.update!(password: "s3nha-forte-1")
    expect(maintainer.enrolled?).to be(false)

    Mfa::Enroll.call(maintainer)
    expect(maintainer.reload.enrolled?).to be(false)

    maintainer.update!(otp_enabled_at: Time.current)
    expect(maintainer.reload.enrolled?).to be(true)
  end

  it "locks the account after five failures and stays locked with the right password" do
    maintainer = build_maintainer

    (described_class::LOCKOUT_ATTEMPTS - 1).times { maintainer.register_failure! }
    expect(maintainer.reload.locked?).to be(false)

    maintainer.register_failure!
    expect(maintainer.reload.locked?).to be(true)
    expect(maintainer.locked_until).to be_within(5.seconds).of(described_class::LOCKOUT_WINDOW.from_now)

    travel_to(described_class::LOCKOUT_WINDOW.from_now + 1.second) do
      expect(maintainer.reload.locked?).to be(false)
    end
  end

  # I1 (fix round 2): sem isto, `failed_attempts` ficava no teto para sempre
  # depois do primeiro bloqueio — vencidos os 15 minutos, UM erro isolado já
  # re-bloqueava a conta, indefinidamente, e esta fatia não tem desbloqueio.
  # `now()` é hora do BANCO: travel_to não a move, então o bloqueio vencido é
  # escrito direto na linha.
  it "restarts the count at one when the previous lock has expired" do
    maintainer = build_maintainer
    described_class::LOCKOUT_ATTEMPTS.times { maintainer.register_failure! }
    expect(maintainer.reload.locked?).to be(true)

    maintainer.update_columns(locked_until: 1.second.ago)
    maintainer.register_failure!

    expect(maintainer.reload.failed_attempts).to eq(1)
    expect(maintainer.locked_until).to be_nil
    expect(maintainer.locked?).to be(false)
  end

  it "clears the failure count on a good login" do
    maintainer = build_maintainer
    2.times { maintainer.register_failure! }

    maintainer.clear_failures!

    expect(maintainer.reload.failed_attempts).to eq(0)
    expect(maintainer.locked_until).to be_nil
  end

  it "deactivates, killing every session at once" do
    maintainer = build_maintainer
    build_maintainer # segundo mantenedor ativo: `deactivate!` recusa o último ativo (Plano 3)
    maintainer.maintainer_sessions.create!(mfa_verified_at: Time.current, last_seen_at: Time.current)

    maintainer.deactivate!

    expect(maintainer.reload.active?).to be(false)
    expect(MaintainerSession.where(maintainer_id: maintainer.id)).to be_empty
  end

  it "knows it is the last active maintainer" do
    first = build_maintainer
    expect(first.last_active?).to be(true)

    second = build_maintainer
    expect(first.reload.last_active?).to be(false)

    second.deactivate!
    expect(first.reload.last_active?).to be(true)
  end

  # Bloco aninhado: aqui `described_class` seria MaintainerInvitation, então o
  # mantenedor é criado pelo nome da classe, não por described_class.
  describe MaintainerInvitation do
    it "stores only a digest and is usable once, inside the window" do
      maintainer = Maintainer.create!(email_address: "inv-#{SecureRandom.hex(3)}@rotasaude.app")
      invitation, token = MaintainerInvitation.issue!(maintainer: maintainer)

      expect(token).to be_present
      expect(invitation.token_digest).not_to include(token)
      expect(MaintainerInvitation.find_by(token_digest: MaintainerInvitation.digest_for(token))).to eq(invitation)
      expect(invitation.usable?).to be(true)

      invitation.update!(used_at: Time.current)
      expect(invitation.reload.usable?).to be(false)

      other, _token = MaintainerInvitation.issue!(maintainer: maintainer)
      travel_to(MaintainerInvitation::TTL.from_now + 1.second) { expect(other.reload.usable?).to be(false) }
    end
  end

  # I3 (fix round 2): o código de TOTP é CONSUMIDO. Dentro da janela de drift
  # (Mfa::Verify::DRIFT) o mesmo código continuava válido por ~90 segundos, em
  # qualquer endpoint: o que verificou a sessão no navegador ainda emitia, logo
  # depois, um token de serviço de 90 dias.
  describe "#consume_totp!" do
    let(:secret) { ROTP::Base32.random }
    let(:maintainer) do
      described_class.create!(email_address: "otp-#{SecureRandom.hex(3)}@rotasaude.app",
                              otp_secret: secret, otp_enabled_at: Time.current)
    end

    it "accepts a code once and refuses the very same code afterwards" do
      code = ROTP::TOTP.new(secret).now

      expect(maintainer.consume_totp!(code)).to be(true)
      expect(maintainer.reload.last_otp_step).to be_present
      expect(maintainer.consume_totp!(code)).to be(false)
    end

    it "refuses a code from an earlier step, still inside the drift window" do
      travel_to(Time.current) do
        previous = ROTP::TOTP.new(secret).at(Mfa::Verify::DRIFT.seconds.ago)
        current = ROTP::TOTP.new(secret).now

        expect(maintainer.consume_totp!(current)).to be(true)
        expect(maintainer.consume_totp!(previous)).to be(false)
      end
    end

    it "accepts the next step, and refuses a wrong or blank code without consuming anything" do
      expect(maintainer.consume_totp!(ROTP::TOTP.new(secret).now)).to be(true)
      consumed = maintainer.reload.last_otp_step

      expect(maintainer.consume_totp!("000000")).to be(false)
      expect(maintainer.consume_totp!(nil)).to be(false)
      expect(maintainer.reload.last_otp_step).to eq(consumed)

      travel(2.minutes) do
        expect(maintainer.consume_totp!(ROTP::TOTP.new(secret).now)).to be(true)
        expect(maintainer.reload.last_otp_step).to be > consumed
      end
    end

    # A trava vale para MANTENEDOR e só para ele: mexer em User/Operator
    # mudaria o app de cidadão e o console, que não são o achado desta rodada.
    it "leaves Mfa::Verify.totp_valid? — the path User and Operator use — replayable" do
      code = ROTP::TOTP.new(secret).now

      expect(Mfa::Verify.totp_valid?(maintainer, code)).to be(true)
      expect(Mfa::Verify.totp_valid?(maintainer, code)).to be(true)
    end
  end
end

# Fix round 1 (Important): `last_active?` era um SELECT sem trava dentro de
# uma transação de isolamento padrão — duas desativações concorrentes nos
# dois últimos mantenedores ativos liam uma a outra como ativa, as duas
# passavam na checagem e as duas commitavam: zero mantenedores ativos,
# exatamente o que a guarda existe para impedir (TOCTOU). Real threads
# racing against the real platform database (not transactional fixtures —
# same pattern as spec/commands/city_lifecycle/invite_admin_spec.rb, which
# exercises the same pg_advisory_xact_lock mechanism) is the only way to
# actually exercise the Postgres advisory lock.
RSpec.describe "Maintainer#deactivate! concurrency safety (fix round 1)" do
  self.use_transactional_tests = false

  # use_transactional_tests = false means these writes really commit to the
  # platform database (needed to exercise a real Postgres advisory lock
  # across two threads/connections) — clean up everything this example
  # commits so it doesn't leak into other specs that count or list
  # Maintainer.active.
  let(:maintainer_a) { Maintainer.create!(email_address: "race-a-#{SecureRandom.hex(4)}@rotasaude.app") }
  let(:maintainer_b) { Maintainer.create!(email_address: "race-b-#{SecureRandom.hex(4)}@rotasaude.app") }

  after do
    Maintainer.where(id: [ maintainer_a.id, maintainer_b.id ]).delete_all
  end

  it "lets exactly one of two concurrent deactivations of the last two active maintainers win" do
    maintainer_a
    maintainer_b

    ready = Queue.new
    go = Queue.new
    outcomes = Queue.new

    threads = [ maintainer_a, maintainer_b ].map do |maintainer|
      Thread.new do
        ready << true
        go.pop
        begin
          Maintainer.find(maintainer.id).deactivate!
          outcomes << :ok
        rescue Maintainer::LastActive
          outcomes << :last_active
        end
      end
    end

    2.times { ready.pop }
    2.times { go << true }
    threads.each(&:join)

    results = Array.new(2) { outcomes.pop }
    expect(results).to contain_exactly(:ok, :last_active)
    expect(Maintainer.active.where(id: [ maintainer_a.id, maintainer_b.id ]).count).to eq(1)
  end

end

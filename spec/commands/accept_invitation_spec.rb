require "rails_helper"

RSpec.describe AcceptInvitation do
  # invited_by is a User OF THIS CITY: invitations.invited_by_id is an FK to the
  # city's own users table (no more platform_operator inviting cross-tenant).
  let!(:inviter) { User.create!(email_address: "admin@example.org", password: "secret123") }
  let!(:inv) do
    Invitation.create!(
      email: "new@example.org", role: "municipal_admin",
      token: "abc123", invited_by: inviter, expires_at: 1.day.from_now
    )
  end

  # membership.granted is a CITY event (Ruling R18): DomainEvents.publish needs
  # Current.city set — the harness only opens the connection.
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "cria user + membership a partir do convite" do
    res = described_class.call(token: "abc123", password: "secretpw-long")
    expect(res.ok?).to be true
    user = res.payload[:user]
    expect(Membership.where(user: user, role: "municipal_admin").exists?).to be true
    expect(inv.reload.accepted_at).to be_present
  end

  it "rejeita token inválido" do
    res = described_class.call(token: "nope", password: "x")
    expect(res.failure?).to be true
  end

  # Provisionamento (Plano 4): o convite do primeiro municipal_admin vem da
  # plataforma — ainda não existe usuário na cidade para ser invited_by.
  it "aceita convite da plataforma (sem invited_by) e grava a membership sem granted_by" do
    Invitation.create!(email: "primeira@example.org", role: "municipal_admin", token: "plataforma-1",
                       invited_by: nil, expires_at: 1.day.from_now)

    res = described_class.call(token: "plataforma-1", password: "secretpw-long")

    expect(res.ok?).to be true
    expect(Membership.find_by!(user: res.payload[:user], role: "municipal_admin").granted_by_id).to be_nil
  end

  # Invariante de fechamento do módulo 06: convite vencido não vira conta.
  it "convite vencido: falha :expired sem criar usuário nem membership, e segue não aceito" do
    inv.update_column(:expires_at, 1.minute.ago)

    res = nil
    expect { res = described_class.call(token: "abc123", password: "secretpw-long") }
      .not_to change { [ User.count, Membership.count, Identity.count ] }
    expect(res.reason).to eq(:expired)
    expect(inv.reload.accepted_at).to be_nil
  end

  it "token já aceito não vale de novo" do
    described_class.call(token: "abc123", password: "secretpw-long")

    res = nil
    expect { res = described_class.call(token: "abc123", password: "outra-senha-longa") }.not_to change(User, :count)
    expect(res.failure?).to be(true)
    expect(res.reason).to eq(:invalid_token)
  end

  it "e-mail que já é usuário da cidade: falha :already_member em vez de levantar" do
    User.create!(email_address: "new@example.org", password: "secret123")

    res = described_class.call(token: "abc123", password: "secretpw-long")

    expect(res.reason).to eq(:already_member)
    expect(inv.reload.accepted_at).to be_nil
  end

  it "senha com menos de 12 caracteres: falha :weak_password sem criar nada" do
    res = nil
    expect { res = described_class.call(token: "abc123", password: "curta-11chr") }.not_to change(User, :count)
    expect(res.reason).to eq(:weak_password)
    expect(inv.reload.accepted_at).to be_nil
  end

  # Corrida de dois aceites do mesmo token: o segundo leu o convite ainda
  # pendente, mas a linha travada já está aceita — não cria outra conta.
  it "relê o convite depois de travar a linha: aceito no meio do caminho não vira segunda conta" do
    stale = Invitation.find(inv.id)
    Invitation.where(id: inv.id).update_all(accepted_at: Time.current)
    allow(Invitation).to receive(:find_by).with(token: "abc123").and_return(stale)

    res = nil
    expect { res = described_class.call(token: "abc123", password: "secretpw-long") }.not_to change(User, :count)
    expect(res.reason).to eq(:invalid_token)
  end

  it "relê o convite depois de travar a linha: vencido no meio do caminho falha :expired" do
    stale = Invitation.find(inv.id)
    Invitation.where(id: inv.id).update_all(expires_at: 1.minute.ago)
    allow(Invitation).to receive(:find_by).with(token: "abc123").and_return(stale)

    res = nil
    expect { res = described_class.call(token: "abc123", password: "secretpw-long") }.not_to change(User, :count)
    expect(res.reason).to eq(:expired)
  end

  it "e-mail criado por outro aceite concorrente (índice único) vira :already_member, sem levantar" do
    allow(User).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "index_users_on_lower_email")

    res = described_class.call(token: "abc123", password: "secretpw-long")

    expect(res.reason).to eq(:already_member)
    expect(inv.reload.accepted_at).to be_nil
  end
end

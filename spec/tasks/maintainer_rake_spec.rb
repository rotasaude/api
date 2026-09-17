require "rails_helper"
require "rake"

# Spec da API de manutenção §6: o PRIMEIRO mantenedor de cada ambiente sai daqui,
# no servidor — não há como convidá-lo pela API, porque ninguém existiria para
# conceder. A mesma task reconvida quem perdeu a janela de 24h.
#
# Segue o padrão de spec/tasks/city_rake_spec.rb (before(:all) carrega as tasks
# uma vez; reenable antes de cada invoke) em vez de recarregar Rake::Task a cada
# chamada — o esboço do brief fazia isso, mas o padrão já estabelecido no
# projeto é mais simples e suficiente aqui.
RSpec.describe "maintainer rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("maintainer:invite")
  end

  def invoke(email)
    Rake::Task["maintainer:invite"].reenable
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task["maintainer:invite"].invoke(email)
    $stdout.string
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it "creates the maintainer, prints a masked e-mail and a usable invitation URL" do
    output = invoke("primeiro@rotasaude.app")

    maintainer = Maintainer.find_by(email_address: "primeiro@rotasaude.app")
    expect(maintainer).to be_present
    expect(maintainer.maintainer_invitations.count).to eq(1)
    expect(output).to include("p***@rotasaude.app")
    expect(output).not_to include("primeiro@rotasaude.app")
    # Fragmento (#), não path (fix round 1): o navegador nunca envia o
    # fragmento ao servidor, então o token não aparece em log de acesso.
    expect(output).to match(%r{/invitations#[A-Za-z0-9_-]{20,}})
    expect(PlatformEvent.where(name: "maintenance.maintainer.invited").count).to eq(1)
  end

  it "re-invites an existing maintainer with a brand new token, invalidating the old one" do
    invoke("segundo@rotasaude.app")
    first_digest = Maintainer.find_by(email_address: "segundo@rotasaude.app").maintainer_invitations.last.token_digest

    invoke("segundo@rotasaude.app")
    invitations = Maintainer.find_by(email_address: "segundo@rotasaude.app").maintainer_invitations.order(:created_at)

    expect(invitations.count).to eq(2)
    expect(invitations.last.token_digest).not_to eq(first_digest)
    # Convite é EXCLUSIVO (fix round 1): o convite antigo é SUPERADO pelo novo,
    # não deixado pendente — a mesma reconvida que corrigiu "dois links vivos"
    # também corrige aqui.
    expect(invitations.first.reload.used_at).to be_present
    expect(invitations.first.usable?).to be(false)
  end

  it "refuses an invalid e-mail and a deactivated maintainer" do
    expect { invoke("nao-e-email") }.to raise_error(SystemExit)

    invoke("terceiro@rotasaude.app")
    Maintainer.create!(email_address: "second-#{SecureRandom.hex(3)}@rotasaude.app") # último ativo não desativa (Plano 3)
    Maintainer.find_by(email_address: "terceiro@rotasaude.app").deactivate!
    expect { invoke("terceiro@rotasaude.app") }.to raise_error(SystemExit)
  end
end

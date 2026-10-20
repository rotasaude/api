require "rails_helper"

RSpec.describe TestServerGuard do
  it "aceita o servidor de teste" do
    expect { described_class.verify!("rota_saude_test", {}) }.not_to raise_error
  end

  it "recusa outro servidor, nomeando o esperado e o recebido" do
    expect { described_class.verify!("", {}) }
      .to raise_error(TestServerGuard::WrongServer, /rota_saude_test.*""/m)
  end

  it "só desliga com TEST_SERVER_GUARD=off explícito (CI)" do
    expect { described_class.verify!("", { "TEST_SERVER_GUARD" => "off" }) }.not_to raise_error
    expect { described_class.verify!("", { "TEST_SERVER_GUARD" => "0" }) }
      .to raise_error(TestServerGuard::WrongServer)
  end
end

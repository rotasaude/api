require "rails_helper"

# /dev/impersonate cria uma sessão de municipal_admin SEM credencial nenhuma.
# Ela existe só em development, e a garantia é o roteador: o bloco em
# config/routes.rb está dentro de `if Rails.env.development?`, então fora de dev
# a rota não é desenhada.
#
# Este spec é irmão de maintenance_route_spec.rb, mas o que ele protege é de
# outra ordem. Se a TELA vazar, alguém lê configuração. Se ESTA rota vazar,
# alguém entra como administrador de qualquer cidade, sem senha e sem MFA. Por
# isso a ação também checa Rails.env.development? por dentro: aqui a duplicação
# de guarda se justifica, porque a consequência de a primeira falhar mudou de
# ordem de grandeza.
RSpec.describe "the impersonation route is development-only" do
  it "does not exist outside development" do
    expect(Rails.env.development?).to be(false)

    expect { Rails.application.routes.recognize_path("/dev/impersonate") }
      .to raise_error(ActionController::RoutingError)
  end

  # A segunda guarda, provada de forma independente da primeira: mesmo que
  # alguém desenhe a rota por engano fora do `if`, a ação recusa. Um spec que
  # só olhasse o roteador não veria esta linha desaparecer.
  it "refuses inside the action too, not only at the router" do
    controller = Dev::ImpersonationsController.new

    expect(controller.send(:development_only?)).to be(false)
  end

  # O impersonate de OPERADOR é mais forte que o de cidade: ele carimba
  # mfa_verified_at sem TOTP nenhum, e o console é de onde se provisiona cidade,
  # se registra canal e se EMITE GRANT para entrar em qualquer cidade. Por isso
  # tem três guardas, não duas — a terceira é require_console_host, herdada de
  # Operators::BaseController, que já recusa host que não seja admin.*.
  describe "the operator impersonation route" do
    it "does not exist outside development" do
      expect { Rails.application.routes.recognize_path("/dev/impersonate_operator") }
        .to raise_error(ActionController::RoutingError)
    end

    it "refuses inside the action too" do
      expect(Dev::OperatorImpersonationsController.new.send(:development_only?)).to be(false)
    end

    # A guarda de host vem da herança, e é o que impede a rota de responder num
    # subdomínio de cidade. Provada aqui porque um spec que só olhasse o
    # roteador não veria a superclasse mudar.
    it "inherits the console-host guard instead of resolving a city" do
      expect(Dev::OperatorImpersonationsController.ancestors).to include(Operators::BaseController)
      expect(Dev::OperatorImpersonationsController.ancestors).not_to include(CityResolution)
    end
  end
end

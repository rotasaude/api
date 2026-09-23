require "rails_helper"

# F1 (final-fix-brief.md, 2026-09-23): `request.remote_ip` (ActionDispatch::RemoteIp)
# levanta IpSpoofAttackError — um StandardError — quando os cabeçalhos Client-IP
# e X-Forwarded-For divergem. `notify_authenticator_change` tem um
# `rescue StandardError` ao redor do envio inteiro; sem tratar o IP à parte,
# esse erro cancelaria o aviso por completo.
#
# Por que este spec não é um :request spec com cabeçalhos divergentes: o
# próprio Rails levanta IpSpoofAttackError ao logar a requisição (Rails::Rack::
# Logger#started_request_message chama request.remote_ip antes de qualquer
# before_action rodar), então a requisição nunca chega ao controller — nem ao
# rate_limit, nem à action. Provado em spec/requests/_scratch_f1_probe_spec.rb
# (descartado) antes deste arquivo: a exceção sobe direto do middleware de
# log, incondicionalmente. Por isso o comportamento é provado aqui, no nível
# do método privado, com um double de `request` que levanta o mesmo erro.
RSpec.describe MfaController do
  describe "#notify_authenticator_change" do
    let!(:user) { User.create!(email_address: "ivy-#{SecureRandom.hex(3)}@example.org", password: "secret123") }
    let!(:session) { user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1") }

    before { Current.session = session }

    def controller_with_spoofed_request
      controller = MfaController.new
      spoofed_request = instance_double(ActionDispatch::Request)
      allow(spoofed_request).to receive(:remote_ip)
        .and_raise(ActionDispatch::RemoteIp::IpSpoofAttackError, "IP spoofing attack?!")
      controller.define_singleton_method(:request) { spoofed_request }
      controller
    end

    it "o aviso sai com \"desconhecido\" no lugar do IP quando remote_ip levanta IpSpoofAttackError" do
      delivery = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
      expect(SecurityMailer).to receive(:authenticator_changed)
        .with(hash_including(ip_address: "desconhecido"))
        .and_return(delivery)

      controller_with_spoofed_request.send(:notify_authenticator_change, replacing: false)
    end
  end
end

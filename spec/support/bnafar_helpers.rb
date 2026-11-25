require "net/http"
require_relative "../../lib/fake_bnafar/app"

# spec/support/bnafar_helpers.rb
# Módulo 27b: o SI-BNAFAR simulado (FakeBnafar::App) servido por WebMock#to_rack
# em http://fake-bnafar.test:8095. Nenhuma spec bate em URL real. Os demais
# helpers do módulo entram nas tasks seguintes.
FAKE_BNAFAR_BASE = "http://fake-bnafar.test:8095".freeze

module BnafarHelpers
  # Liga o simulado (um novo, ou o passado) à base de teste e devolve a instância.
  def fake_bnafar!(app = FakeBnafar::App.new)
    stub_request(:any, /\A#{Regexp.escape(FAKE_BNAFAR_BASE)}/).to_rack(app)
    app
  end
end

RSpec.configure { |c| c.include BnafarHelpers }

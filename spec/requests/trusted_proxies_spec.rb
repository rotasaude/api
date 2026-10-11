# spec/requests/trusted_proxies_spec.rb
require "rails_helper"

# Card api#62: os rate_limit contam por request.remote_ip. Atrás do proxy de
# borda da cidade, só com o CIDR do proxy em trusted_proxies o Rails enxerga o
# IP real do cidadão; sem isso todos dividem um balde, ou um cliente forja
# X-Forwarded-For. O middleware lê `proxies` a cada requisição, então o stub
# troca a lista sem tocar o código de produção (em test o config não vem do env).
RSpec.describe "IP real atrás do proxy de borda", type: :request do
  let(:proxy) { "198.51.100.7" }
  let(:untrusted) { "192.0.2.99" }
  let(:lookup) { { short_code: "AAAAA-AAAAA", birth_year: 1980 } }

  before do
    documents_city!
    Rails.cache.clear
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    list = Rota.trusted_proxies("198.51.100.0/24")
    allow_any_instance_of(ActionDispatch::RemoteIp).to receive(:proxies).and_return(list)
  end

  def lookup_from(remote_addr, forwarded)
    post "/v/lookup", params: lookup.to_json,
                      headers: { "CONTENT_TYPE" => "application/json", "X-Forwarded-For" => forwarded },
                      env: { "REMOTE_ADDR" => remote_addr }
  end

  it "proxy confiável: remote_ip é o IP do cliente do X-Forwarded-For" do
    seen = nil
    allow_any_instance_of(DocumentVerificationsController).to receive(:lookup) do |controller|
      seen = controller.request.remote_ip
      controller.head :ok
    end
    lookup_from(proxy, "203.0.113.50")
    expect(seen).to eq("203.0.113.50")
  end

  it "/v/lookup: dois clientes atrás do mesmo proxy confiável não dividem o balde" do
    10.times { lookup_from(proxy, "203.0.113.50") }
    lookup_from(proxy, "203.0.113.50")
    expect(response).to have_http_status(:too_many_requests)
    lookup_from(proxy, "203.0.113.51")
    expect(response).not_to have_http_status(:too_many_requests)
  end

  # O Rails descarta os proxies confiáveis da DIREITA do X-Forwarded-For e fica
  # com o primeiro que sobra: o proxy confiável anexa o IP real à direita, então
  # o que o cliente forjou à esquerda não conta. (Um par direto NÃO confiável
  # teria o XFF aceito como está — na topologia real todo tráfego passa pelo
  # proxy de borda, por isso a lista precisa estar certa.)
  it "proxy confiável: o valor forjado à esquerda do X-Forwarded-For é ignorado e não escapa do balde" do
    seen = nil
    allow_any_instance_of(DocumentVerificationsController).to receive(:lookup) do |controller|
      seen = controller.request.remote_ip
      controller.head :ok
    end
    lookup_from(proxy, "9.9.9.9, 203.0.113.50")
    expect(seen).to eq("203.0.113.50")

    allow_any_instance_of(DocumentVerificationsController).to receive(:lookup).and_call_original
    10.times { |i| lookup_from(proxy, "9.9.9.#{i}, 203.0.113.50") }
    lookup_from(proxy, "8.8.8.8, 203.0.113.50")
    expect(response).to have_http_status(:too_many_requests)
  end

  # Topologia real: proxy de borda (IP público) -> kamal-proxy (rede docker
  # privada) -> container. REMOTE_ADDR é privado; o XFF chega "cliente, borda".
  it "cadeia borda -> kamal-proxy: com o CIDR da borda na lista, cada cliente tem o seu balde" do
    10.times { lookup_from("172.18.0.3", "203.0.113.50, 198.51.100.7") }
    lookup_from("172.18.0.3", "203.0.113.50, 198.51.100.7")
    expect(response).to have_http_status(:too_many_requests)
    lookup_from("172.18.0.3", "203.0.113.51, 198.51.100.7")
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "sem o CIDR da borda na lista (o problema do card): todos os clientes dividem o IP da borda" do
    allow_any_instance_of(ActionDispatch::RemoteIp).to receive(:proxies).and_return(ActionDispatch::RemoteIp::TRUSTED_PROXIES)
    10.times { |i| lookup_from("172.18.0.3", "203.0.113.#{i + 1}, 198.51.100.7") }
    lookup_from("172.18.0.3", "203.0.113.200, 198.51.100.7")
    expect(response).to have_http_status(:too_many_requests)
  end
end

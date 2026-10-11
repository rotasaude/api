# Card api#62: em production/staging sem TRUSTED_PROXIES, avisa no log do boot
# que o limite por IP vê o IP do proxy de borda (não quebra o boot; o valor é
# gate de go-live). A configuração em si está em config/environments/production.rb.
Rota.warn_missing_trusted_proxies

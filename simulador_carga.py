#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
import random
import time
import argparse
from datetime import datetime

try:
    import aiohttp
except ImportError:
    print("Erro: A biblioteca 'aiohttp' é necessária para alta concorrência.")
    print("Instale com: pip3 install aiohttp")
    exit(1)

# Configuração de Bounding Box (Aproximadamente cidade de São Paulo)
LAT_MIN, LAT_MAX = -23.8, -23.3
LON_MIN, LON_MAX = -46.9, -46.3

# Dicionário global para agregar as métricas de performance
metrics = {
    "requests": 0,
    "success": 0,
    "errors": 0,
    "total_time": 0.0
}

def update_metrics(status, elapsed):
    metrics["requests"] += 1
    metrics["total_time"] += elapsed
    if status == 200:
        metrics["success"] += 1
    else:
        metrics["errors"] += 1

async def reporter_worker(report_interval):
    """Exibe na tela os resultados das métricas de X em X segundos"""
    while True:
        await asyncio.sleep(report_interval)
        reqs = metrics["requests"]
        if reqs > 0:
            avg_resp = (metrics["total_time"] / reqs) * 1000
            print(f"[{datetime.now().strftime('%H:%M:%S')}] "
                  f"Reqs/s: {reqs/report_interval:.1f} | Sucesso: {metrics['success']} | "
                  f"Erros: {metrics['errors']} | Tempo Med Resp: {avg_resp:.2f}ms")
        else:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] Aguardando envios...")
        
        # Reset counters para a próxima janela
        metrics["requests"] = 0
        metrics["success"] = 0
        metrics["errors"] = 0
        metrics["total_time"] = 0.0

async def device_worker(session, traccar_url, device_id, send_interval):
    """Simula um único Dispositivo andando aleatoriamente pela cidade"""
    lat = random.uniform(LAT_MIN, LAT_MAX)
    lon = random.uniform(LON_MIN, LON_MAX)
    speed = random.uniform(0, 80)
    
    while True:
        # Movimentação aleatória simples (random walk) simulando GPS drift / pequenas viagens.
        lat += random.uniform(-0.002, 0.002)
        lon += random.uniform(-0.002, 0.002)
        speed = max(0, min(120, speed + random.uniform(-5, 5)))
        timestamp = int(datetime.utcnow().timestamp())
        
        # Protocolo OsmAnd (Nativo no Traccar pela porta 5055 default)
        url = f"{traccar_url}/?id={device_id}&lat={lat:.6f}&lon={lon:.6f}&speed={speed:.1f}&timestamp={timestamp}"
        
        start_time = time.time()
        try:
            async with session.get(url, timeout=5) as response:
                status = response.status
        except Exception:
            status = 0 # Considera timeout ou erro de rota
            
        elapsed = time.time() - start_time
        
        update_metrics(status, elapsed)
        
        # Aguarda o intervalo de envio estabelecido antes do próximo ponto
        await asyncio.sleep(send_interval)


async def main():
    parser = argparse.ArgumentParser(description="Simulador de Carga - Traccar (OsmAnd)")
    parser.add_argument("--url", default="http://127.0.0.1:5055", help="URL do Traccar (comporta a porta OsmAnd)")
    parser.add_argument("--devices", type=int, default=1000, help="Quantidade de dispositivos rodando simultaneamente")
    parser.add_argument("--interval", type=float, default=15.0, help="Intervalo de comunicação de CADA dispositivo (segs)")
    parser.add_argument("--prefix", default="SIM_LOAD_", help="Prefixo que os devices receberão (IMEI fictício)")
    
    args = parser.parse_args()
    
    print("="*60)
    print("🚀 INICIANDO BOT DE SIMULAÇÃO DE CARGA TRACCAR")
    print("="*60)
    print(f"🌐 Alvo.........: {args.url}")
    print(f"📱 Dispositivos.: {args.devices}")
    print(f"⏱️  Intervalo....: {args.interval}s por dispositivo")
    
    req_per_sec = args.devices / args.interval
    print(f"⚙️  Carga Est....: ~{req_per_sec:.2f} Requisições por Segundo (RPS)")
    print("="*60)
    print("Pressione CTRL+C para cancelar\n")
    
    # Criar um conector customizado para evitar abrir e fechar centenas de portas de saída do OS
    connector = aiohttp.TCPConnector(limit=max(100, args.devices // 2))
    
    async with aiohttp.ClientSession(connector=connector) as session:
        # Dispara logador a cada 5 segundos
        asyncio.create_task(reporter_worker(5.0))
        
        tasks = []
        for i in range(args.devices):
            device_id = f"{args.prefix}{i+1:05d}" # Gera IDs: SIM_LOAD_00001
            
            # Espalhar o start_time inicial sutilmente e aleatoriamente 
            # para não socar 10.000 requests simultâneos no ms 1
            await asyncio.sleep(random.uniform(0.01, 0.1))
            
            tasks.append(asyncio.create_task(device_worker(session, args.url, device_id, args.interval)))
            
        await asyncio.gather(*tasks)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\n🛑 Simulação finalizada com sucesso.")

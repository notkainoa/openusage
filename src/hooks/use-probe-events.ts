import { useCallback, useEffect, useRef } from "react"
import { listen, type UnlistenFn } from "@tauri-apps/api/event"
import { invoke } from "@tauri-apps/api/core"
import type { PluginOutput } from "@/lib/plugin-types"

type ProbeResult = {
  batchId: string
  output: PluginOutput
}

type ProbeBatchComplete = {
  batchId: string
}

type ProbeBatchStarted = {
  batchId: string
  pluginIds: string[]
}

type UseProbeEventsOptions = {
  onResult: (result: ProbeResult) => void
  onBatchComplete: () => void
}

type StartBatchOptions = {
  batchId?: string
}

function createBatchId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `batch-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

export function useProbeEvents({ onResult, onBatchComplete }: UseProbeEventsOptions) {
  const activeBatchIds = useRef<Set<string>>(new Set())
  const unlisteners = useRef<UnlistenFn[]>([])
  const listenersReadyRef = useRef<Promise<void> | null>(null)
  const listenersReadyResolveRef = useRef<(() => void) | null>(null)

  useEffect(() => {
    let cancelled = false

    // Create the promise that will resolve when listeners are ready
    listenersReadyRef.current = new Promise<void>((resolve) => {
      listenersReadyResolveRef.current = resolve
    })

    const setup = async () => {
      const resultUnlisten = await listen<ProbeResult>("probe:result", (event) => {
        if (activeBatchIds.current.has(event.payload.batchId)) {
          onResult(event.payload)
        }
      })

      if (cancelled) {
        resultUnlisten()
        return
      }

      const completeUnlisten = await listen<ProbeBatchComplete>(
        "probe:batch-complete",
        (event) => {
          if (activeBatchIds.current.delete(event.payload.batchId)) {
            onBatchComplete()
          }
        }
      )

      if (cancelled) {
        resultUnlisten()
        completeUnlisten()
        return
      }

      unlisteners.current.push(resultUnlisten, completeUnlisten)

      // Signal that listeners are ready
      listenersReadyResolveRef.current?.()
    }

    void setup()

    return () => {
      cancelled = true
      unlisteners.current.forEach((unlisten) => unlisten())
      unlisteners.current = []
      listenersReadyRef.current = null
      listenersReadyResolveRef.current = null
    }
  }, [onBatchComplete, onResult])

  const startBatch = useCallback(
    async (pluginIds?: string[], options?: StartBatchOptions) => {
      const requestedBatchId = options?.batchId?.trim()
      const batchId = requestedBatchId ? requestedBatchId : createBatchId()

      // Wait for listeners to be ready before starting the batch
      if (listenersReadyRef.current) {
        await listenersReadyRef.current
      }

      activeBatchIds.current.add(batchId)
      const args = pluginIds
        ? { batchId, pluginIds }
        : { batchId }
      try {
        return await invoke<ProbeBatchStarted>("start_probe_batch", args)
      } catch (error) {
        activeBatchIds.current.delete(batchId)
        throw error
      }
    },
    []
  )

  return { startBatch }
}

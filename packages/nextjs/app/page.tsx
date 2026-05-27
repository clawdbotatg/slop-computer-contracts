"use client";

import { useState } from "react";
import { Address, AddressInput } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const PAGE_SIZE = 10n;
const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as const;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

type Hex32 = `0x${string}`;

type EpisodeForm = {
  name: string;
  slug: string;
  /** relay-room slug; empty means "same as slug" (the contract default) */
  liveSlug: string;
  manifest: string;
  contractAddr: string;
  /** datetime-local value, e.g. "2026-05-09T14:30" — converted to unix seconds before send */
  datetime: string;
};

const emptyForm: EpisodeForm = { name: "", slug: "", liveSlug: "", manifest: "", contractAddr: "", datetime: "" };

const toUnix = (datetimeLocal: string): bigint => {
  if (!datetimeLocal) return 0n;
  const ms = Date.parse(datetimeLocal);
  return Number.isNaN(ms) ? 0n : BigInt(Math.floor(ms / 1000));
};

const formatUnix = (seconds: bigint): string => {
  if (!seconds) return "—";
  return new Date(Number(seconds) * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(/\.\d+Z$/, "Z");
};

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [cursorStack, setCursorStack] = useState<Hex32[]>([ZERO_BYTES32]);
  const [addForm, setAddForm] = useState<EpisodeForm>(emptyForm);
  const [liveForm, setLiveForm] = useState<EpisodeForm>(emptyForm);

  const cursor = cursorStack[cursorStack.length - 1];

  const { data: owner } = useScaffoldReadContract({
    contractName: "SlopComputer",
    functionName: "owner",
  });

  const { data: episodeCount } = useScaffoldReadContract({
    contractName: "SlopComputer",
    functionName: "episodeCount",
  });

  // Single read for the live hero — returns zero-struct when offline.
  const { data: liveEpisodeData } = useScaffoldReadContract({
    contractName: "SlopComputer",
    functionName: "liveEpisode",
  });

  // Fetch two extra so we can both (a) tell whether more pages exist and
  // (b) absorb the loss of the live entry when it falls inside this batch.
  const { data: rawEpisodes } = useScaffoldReadContract({
    contractName: "SlopComputer",
    functionName: "getEpisodesFrom",
    args: [cursor, PAGE_SIZE + 2n],
  });

  const { writeContractAsync, isPending } = useScaffoldWriteContract({
    contractName: "SlopComputer",
  });

  const isOwner = !!connectedAddress && !!owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const heroEpisode = liveEpisodeData && liveEpisodeData.id !== ZERO_BYTES32 ? liveEpisodeData : undefined;
  const isLive = !!heroEpisode;
  const liveId = heroEpisode?.id;

  const filtered = (rawEpisodes ?? []).filter(ep => !liveId || ep.id !== liveId);
  const visible = filtered.slice(0, Number(PAGE_SIZE));
  const hasMore = filtered.length > Number(PAGE_SIZE);

  const pastCount = episodeCount === undefined ? undefined : isLive ? episodeCount - 1n : episodeCount;
  const pageNumber = cursorStack.length;
  const estimatedPages = pastCount ? Number((pastCount + PAGE_SIZE - 1n) / PAGE_SIZE) : 0;

  const onNext = () => {
    if (!hasMore) return;
    const last = visible[visible.length - 1];
    setCursorStack(stack => [...stack, last.nextId]);
  };

  const onPrev = () => {
    setCursorStack(stack => (stack.length > 1 ? stack.slice(0, -1) : stack));
  };

  const resetPaging = () => setCursorStack([ZERO_BYTES32]);

  const onAdd = async () => {
    await writeContractAsync({
      functionName: "addEpisode",
      args: [
        addForm.name,
        addForm.slug,
        addForm.liveSlug,
        addForm.manifest,
        addForm.contractAddr || ZERO_ADDRESS,
        toUnix(addForm.datetime),
      ],
    });
    setAddForm(emptyForm);
    resetPaging();
  };

  const onGoLive = async () => {
    await writeContractAsync({
      functionName: "goLive",
      args: [
        liveForm.name,
        liveForm.slug,
        liveForm.liveSlug,
        liveForm.manifest,
        liveForm.contractAddr || ZERO_ADDRESS,
        toUnix(liveForm.datetime),
      ],
    });
    setLiveForm(emptyForm);
    resetPaging();
  };

  const onGoOffline = async () => {
    await writeContractAsync({ functionName: "goOffline" });
  };

  const onDelete = async (id: Hex32) => {
    await writeContractAsync({ functionName: "deleteEpisode", args: [id] });
    resetPaging();
  };

  return (
    <div className="flex flex-col items-center grow w-full px-5 py-10">
      <div className="w-full max-w-4xl">
        <h1 className="text-center mb-2">
          <span className="block text-2xl">slop.computer</span>
          <span className="block text-4xl font-bold">Episode Registry</span>
        </h1>

        {/* HERO / LIVE BANNER */}
        {heroEpisode ? (
          <div className="alert alert-error my-6 flex flex-col items-start">
            <div className="flex items-center gap-3">
              <span className="badge badge-error animate-pulse">LIVE</span>
              <span className="text-xl font-bold">{heroEpisode.name}</span>
            </div>
            <div className="text-sm opacity-80 break-all">
              {heroEpisode.slug && <div>/{heroEpisode.slug}</div>}
              {heroEpisode.manifest && <div>{heroEpisode.manifest}</div>}
              <div>{formatUnix(heroEpisode.datetime)}</div>
              <div className="flex items-center gap-2">
                contract: <Address address={heroEpisode.contractAddr} size="xs" />
              </div>
            </div>
          </div>
        ) : (
          <div className="alert my-6">
            <span>Currently offline.</span>
          </div>
        )}

        {/* OWNER PANEL */}
        {isOwner && (
          <div className="card bg-base-200 shadow-lg my-6">
            <div className="card-body">
              <h2 className="card-title">Owner controls</h2>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-2">
                <Panel
                  title="Add episode"
                  form={addForm}
                  setForm={setAddForm}
                  onSubmit={onAdd}
                  submitLabel="Add"
                  disabled={isPending}
                />
                <Panel
                  title={isLive ? "Replace live episode" : "Go live"}
                  form={liveForm}
                  setForm={setLiveForm}
                  onSubmit={onGoLive}
                  submitLabel={isLive ? "Replace live" : "Go live"}
                  disabled={isPending}
                />
              </div>

              {isLive && (
                <button className="btn btn-warning mt-2" onClick={onGoOffline} disabled={isPending}>
                  Go offline
                </button>
              )}
            </div>
          </div>
        )}

        {/* EPISODE LIST */}
        <div className="card bg-base-200 shadow-lg my-6">
          <div className="card-body">
            <div className="flex justify-between items-center">
              <h2 className="card-title">Episodes ({pastCount?.toString() ?? "…"})</h2>
              <div className="join">
                <button className="btn btn-sm join-item" disabled={pageNumber === 1} onClick={onPrev}>
                  «
                </button>
                <button className="btn btn-sm join-item no-animation pointer-events-none">
                  page {pageNumber}
                  {estimatedPages ? ` / ${estimatedPages}` : ""}
                </button>
                <button className="btn btn-sm join-item" disabled={!hasMore} onClick={onNext}>
                  »
                </button>
              </div>
            </div>

            {visible.length === 0 ? (
              <p className="opacity-70">No episodes on this page.</p>
            ) : (
              <ul className="flex flex-col gap-3 mt-2">
                {visible.map(ep => (
                  <li key={ep.id} className="p-3 rounded bg-base-100">
                    <div className="flex justify-between items-start gap-3">
                      <div className="min-w-0">
                        <div className="font-bold">{ep.name}</div>
                        {ep.slug && <div className="text-xs opacity-70 break-all">/{ep.slug}</div>}
                        <div className="text-xs opacity-70 break-all">{formatUnix(ep.datetime)}</div>
                        {ep.manifest && <div className="text-xs opacity-70 break-all">{ep.manifest}</div>}
                        <div className="text-xs flex items-center gap-2 mt-1">
                          contract: <Address address={ep.contractAddr} size="xs" />
                        </div>
                        <div className="text-[10px] opacity-50 break-all mt-1">id: {ep.id}</div>
                      </div>
                      {isOwner && (
                        <button className="btn btn-xs btn-error" disabled={isPending} onClick={() => onDelete(ep.id)}>
                          delete
                        </button>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

type PanelProps = {
  title: string;
  form: EpisodeForm;
  setForm: (f: EpisodeForm) => void;
  onSubmit: () => void;
  submitLabel: string;
  disabled?: boolean;
};

const Panel = ({ title, form, setForm, onSubmit, submitLabel, disabled }: PanelProps) => (
  <div className="bg-base-100 rounded p-3 flex flex-col gap-2">
    <div className="font-bold">{title}</div>
    <input
      className="input input-bordered input-sm"
      placeholder="name"
      value={form.name}
      onChange={e => setForm({ ...form, name: e.target.value })}
    />
    <input
      className="input input-bordered input-sm"
      placeholder="slug (a-z 0-9 -, unique)"
      value={form.slug}
      onChange={e => setForm({ ...form, slug: e.target.value })}
    />
    <input
      className="input input-bordered input-sm"
      placeholder="live slug (a-z 0-9 -, optional — defaults to slug)"
      value={form.liveSlug}
      onChange={e => setForm({ ...form, liveSlug: e.target.value })}
    />
    <input
      className="input input-bordered input-sm"
      placeholder="manifest (ipfs://…, optional while live)"
      value={form.manifest}
      onChange={e => setForm({ ...form, manifest: e.target.value })}
    />
    <AddressInput
      placeholder="contract address (optional)"
      value={form.contractAddr}
      onChange={v => setForm({ ...form, contractAddr: v })}
    />
    <input
      type="datetime-local"
      className="input input-bordered input-sm"
      value={form.datetime}
      onChange={e => setForm({ ...form, datetime: e.target.value })}
    />
    <button className="btn btn-primary btn-sm" disabled={disabled || !form.name || !form.slug} onClick={onSubmit}>
      {submitLabel}
    </button>
  </div>
);

export default Home;

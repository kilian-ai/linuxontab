// SPDX-License-Identifier: MIT

import type { DeviceTreeNode } from "./devicetree.ts";
import type { Machine } from "./index.ts";
import {
  getMachinePlugin,
  type MachinePlugin,
  type MachinePluginInput,
  type MachineSetup,
} from "./plugin.ts";
import { close_virtio_device, type VirtioDevice } from "./virtio/core.ts";

export interface ConfiguredMachine {
  readonly args: readonly string[];
  readonly devices: readonly VirtioDevice[];
  readonly deviceTree: DeviceTreeNode;
  readonly plugins: readonly MachinePlugin[];
}

function is_device_tree_node(value: unknown): value is DeviceTreeNode {
  return typeof value === "object" && value?.constructor === Object;
}

export function merge_device_tree(target: DeviceTreeNode, source: DeviceTreeNode) {
  for (const [name, value] of Object.entries(source)) {
    const current = target[name];
    if (is_device_tree_node(current) && is_device_tree_node(value)) {
      merge_device_tree(current, value);
    } else {
      target[name] = value;
    }
  }
}

function machine_plugin(input: MachinePluginInput): MachinePlugin {
  return getMachinePlugin in input ? input[getMachinePlugin]() : input;
}

export async function configure_machine(
  args: readonly string[],
  inputs: readonly MachinePluginInput[],
): Promise<ConfiguredMachine> {
  const configured_args = [...args];
  const devices: VirtioDevice[] = [];
  const device_tree: DeviceTreeNode = {};
  const setup: MachineSetup = {
    args: {
      add(...next) {
        configured_args.push(...next);
      },
    },
    devices: {
      add(...next) {
        devices.push(...next);
      },
    },
    deviceTree: {
      merge(fragment) {
        merge_device_tree(device_tree, fragment);
      },
    },
  };

  const plugins: MachinePlugin[] = [];
  try {
    for (const input of inputs) {
      const plugin = machine_plugin(input);
      plugins.push(plugin);
      await plugin.configure(setup);
    }
  } catch (error) {
    await Promise.allSettled(devices.map((device) => close_virtio_device(device)));
    throw error;
  }

  return {
    args: configured_args,
    devices,
    deviceTree: device_tree,
    plugins,
  };
}

export async function run_machine_booted(
  plugins: readonly MachinePlugin[],
  machine: Machine,
): Promise<void> {
  for (const plugin of plugins) await plugin.booted?.(machine);
}

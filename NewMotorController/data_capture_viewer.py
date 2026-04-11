#!/usr/bin/env python3
"""
Browse CSV/Excel time-series captures under NewMotorController.

- Pick a file from the folder (dropdown or Left/Right arrows).
- Plot every numeric column vs time in stacked subplots with a shared X axis.
- Optionally show one series at a time (dropdown or Up/Down).
- Set X (time) min/max for all plots at once.
- CSV: Cut overwrites the file with only rows in the current X range (plot zoom or min/max fields).
- CSV: Delete removes the current file from disk (with confirmation).
"""

from __future__ import annotations

import tempfile
import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
import sys

import numpy as np
import pandas as pd

import matplotlib
matplotlib.use("TkAgg")
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk
from matplotlib.figure import Figure


SCRIPT_DIR = Path(__file__).resolve().parent
TIME_CANDIDATES = ("t_rel_s", "time_s", "time", "t_s", "timestamp", "host_unix_s")


def discover_data_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in ("**/*.csv", "**/*.xlsx", "**/*.xls"):
        paths.extend(root.glob(pattern))
    return sorted({p.resolve() for p in paths if p.is_file()}, key=lambda p: str(p).lower())


def pick_time_column(df: pd.DataFrame) -> str | None:
    for name in TIME_CANDIDATES:
        if name in df.columns:
            return name
    for col in df.columns:
        if pd.api.types.is_numeric_dtype(df[col]):
            return col
    return None


def y_numeric_columns(df: pd.DataFrame, time_col: str) -> list[str]:
    cols: list[str] = []
    for c in df.columns:
        if c == time_col:
            continue
        if pd.api.types.is_numeric_dtype(df[c]):
            cols.append(c)
    return cols


def load_dataframe(path: Path, sheet: str | None) -> pd.DataFrame:
    suf = path.suffix.lower()
    if suf == ".csv":
        return pd.read_csv(path, low_memory=False)
    if suf in (".xlsx", ".xls"):
        kwargs: dict = {}
        if sheet is not None:
            kwargs["sheet_name"] = sheet
        return pd.read_excel(path, **kwargs)
    raise ValueError(f"Unsupported format: {path}")


def excel_sheet_names(path: Path) -> list[str] | None:
    if path.suffix.lower() not in (".xlsx", ".xls"):
        return None
    try:
        xl = pd.ExcelFile(path)
        return list(xl.sheet_names)
    except Exception:
        return None


class DataCaptureViewer(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("NewMotorController — capture viewer")
        self.geometry("1100x800")

        self._files = discover_data_files(SCRIPT_DIR)
        self._index = 0
        self._sheet_names: list[str] | None = None
        self._current_sheet: str | None = None
        self._df: pd.DataFrame | None = None
        self._time_col: str | None = None
        self._y_cols: list[str] = []
        self._t_full: tuple[float, float] = (0.0, 1.0)
        self._single_mode = tk.BooleanVar(value=False)
        self._single_idx = 0

        self._build_ui()
        self.bind("<Left>", lambda e: self._prev_file())
        self.bind("<Right>", lambda e: self._next_file())
        self.bind("<Prior>", lambda e: self._prev_series())  # Page Up
        self.bind("<Next>", lambda e: self._next_series())  # Page Down
        self.bind("<Up>", lambda e: self._prev_series())
        self.bind("<Down>", lambda e: self._next_series())

        if not self._files:
            messagebox.showwarning(
                "No data files",
                f"No .csv / .xlsx / .xls files found under:\n{SCRIPT_DIR}",
            )
        else:
            self._load_current_file()

    def _build_ui(self) -> None:
        top = ttk.Frame(self, padding=8)
        top.pack(side=tk.TOP, fill=tk.X)

        self._title_lbl = ttk.Label(top, text="", font=("TkDefaultFont", 12, "bold"))
        self._title_lbl.pack(anchor=tk.W)

        row1 = ttk.Frame(top)
        row1.pack(fill=tk.X, pady=(4, 0))
        ttk.Label(row1, text="File:").pack(side=tk.LEFT)
        self._file_combo = ttk.Combobox(
            row1,
            values=[self._display_path(p) for p in self._files],
            state="readonly",
            width=70,
        )
        self._file_combo.pack(side=tk.LEFT, padx=6, fill=tk.X, expand=True)
        self._file_combo.bind("<<ComboboxSelected>>", self._on_file_combo)
        ttk.Button(row1, text="◀ Prev", command=self._prev_file).pack(side=tk.LEFT, padx=2)
        ttk.Button(row1, text="Next ▶", command=self._next_file).pack(side=tk.LEFT, padx=2)

        self._sheet_row = ttk.Frame(top)
        ttk.Label(self._sheet_row, text="Sheet:").pack(side=tk.LEFT)
        self._sheet_combo = ttk.Combobox(self._sheet_row, state="readonly", width=40)
        self._sheet_combo.pack(side=tk.LEFT, padx=6)
        self._sheet_combo.bind("<<ComboboxSelected>>", self._on_sheet_combo)

        row2 = ttk.Frame(top)
        row2.pack(fill=tk.X, pady=(6, 0))
        ttk.Label(row2, text="Time axis (shared):").pack(side=tk.LEFT)
        ttk.Label(row2, text="min").pack(side=tk.LEFT, padx=(8, 2))
        self._tmin_var = tk.StringVar(value="")
        ttk.Entry(row2, textvariable=self._tmin_var, width=14).pack(side=tk.LEFT)
        ttk.Label(row2, text="max").pack(side=tk.LEFT, padx=(6, 2))
        self._tmax_var = tk.StringVar(value="")
        ttk.Entry(row2, textvariable=self._tmax_var, width=14).pack(side=tk.LEFT)
        ttk.Button(row2, text="Apply", command=self._apply_xlim).pack(side=tk.LEFT, padx=6)
        ttk.Button(row2, text="Reset (full range)", command=self._reset_xlim).pack(side=tk.LEFT, padx=2)
        ttk.Button(row2, text="Cut (crop CSV)", command=self._crop_current_csv).pack(side=tk.LEFT, padx=(12, 2))
        ttk.Button(row2, text="Delete file", command=self._delete_current_file).pack(side=tk.LEFT, padx=2)

        row2b = ttk.Frame(top)
        row2b.pack(fill=tk.X, pady=(2, 0))
        ttk.Label(
            row2b,
            text="Cut: keeps rows whose time column falls in the current X range (matplotlib zoom/pan or min/max above). Rewrites CSV; if t_rel_s exists it is re-zeroed to the crop start.",
            font=("TkDefaultFont", 8),
            foreground="#444",
            wraplength=900,
        ).pack(anchor=tk.W)

        row3 = ttk.Frame(top)
        row3.pack(fill=tk.X, pady=(6, 0))
        ttk.Checkbutton(
            row3,
            text="Show one series at a time",
            variable=self._single_mode,
            command=self._on_mode_change,
        ).pack(side=tk.LEFT)
        ttk.Label(row3, text="Series:").pack(side=tk.LEFT, padx=(12, 2))
        self._series_combo = ttk.Combobox(row3, state="readonly", width=32)
        self._series_combo.pack(side=tk.LEFT)
        self._series_combo.bind("<<ComboboxSelected>>", self._on_series_combo)

        hint = ttk.Label(
            top,
            text="Keys: ← → switch file  |  ↑ ↓ (or PgUp/PgDn) switch series when single-series mode is on",
            font=("TkDefaultFont", 9),
            foreground="gray",
        )
        hint.pack(anchor=tk.W, pady=(4, 0))

        self._fig = Figure(figsize=(10, 8), dpi=100)
        self._fig.set_layout_engine("constrained")
        self._canvas = FigureCanvasTkAgg(self._fig, master=self)
        self._canvas.draw()
        self._canvas.get_tk_widget().pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        self._toolbar = NavigationToolbar2Tk(self._canvas, self)
        self._toolbar.update()

    def _display_path(self, p: Path) -> str:
        try:
            return str(p.relative_to(SCRIPT_DIR))
        except ValueError:
            return str(p)

    def _on_file_combo(self, _evt=None) -> None:
        name = self._file_combo.get()
        for i, p in enumerate(self._files):
            if self._display_path(p) == name:
                self._index = i
                self._load_current_file()
                return

    def _on_sheet_combo(self, _evt=None) -> None:
        self._current_sheet = self._sheet_combo.get() or None
        self._reload_df_only()

    def _on_series_combo(self, _evt=None) -> None:
        name = self._series_combo.get()
        if name in self._y_cols:
            self._single_idx = self._y_cols.index(name)
        self._redraw()

    def _on_mode_change(self) -> None:
        self._redraw()

    def _prev_file(self) -> None:
        if len(self._files) <= 1:
            return
        self._index = (self._index - 1) % len(self._files)
        self._sync_file_combo()
        self._load_current_file()

    def _next_file(self) -> None:
        if len(self._files) <= 1:
            return
        self._index = (self._index + 1) % len(self._files)
        self._sync_file_combo()
        self._load_current_file()

    def _sync_file_combo(self) -> None:
        if self._files:
            self._file_combo.set(self._display_path(self._files[self._index]))

    def _prev_series(self) -> None:
        if not self._single_mode.get() or not self._y_cols:
            return
        self._single_idx = (self._single_idx - 1) % len(self._y_cols)
        self._series_combo.set(self._y_cols[self._single_idx])
        self._redraw()

    def _next_series(self) -> None:
        if not self._single_mode.get() or not self._y_cols:
            return
        self._single_idx = (self._single_idx + 1) % len(self._y_cols)
        self._series_combo.set(self._y_cols[self._single_idx])
        self._redraw()

    def _load_current_file(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        self._sync_file_combo()
        self._title_lbl.configure(text=self._display_path(path))

        sheets = excel_sheet_names(path)
        self._sheet_names = sheets
        if sheets and len(sheets) > 1:
            self._sheet_row.pack(fill=tk.X, pady=(4, 0))
            self._sheet_combo.configure(values=sheets)
            self._current_sheet = sheets[0]
            self._sheet_combo.set(self._current_sheet)
        else:
            self._sheet_row.pack_forget()
            self._current_sheet = sheets[0] if sheets else None

        try:
            self._df = load_dataframe(path, self._current_sheet)
        except Exception as e:
            messagebox.showerror("Load error", f"{path.name}:\n{e}")
            self._df = None
            self._clear_fig()
            return

        self._prepare_columns()
        self._reset_xlim()
        self._redraw()

    def _reload_df_only(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        try:
            self._df = load_dataframe(path, self._current_sheet)
        except Exception as e:
            messagebox.showerror("Load error", f"{path.name}:\n{e}")
            self._df = None
            self._clear_fig()
            return
        self._prepare_columns()
        self._reset_xlim()
        self._redraw()

    def _prepare_columns(self) -> None:
        if self._df is None or self._df.empty:
            self._time_col = None
            self._y_cols = []
            self._series_combo.configure(values=[])
            return
        self._time_col = pick_time_column(self._df)
        if self._time_col is None:
            self._y_cols = []
            self._series_combo.configure(values=[])
            return
        self._y_cols = y_numeric_columns(self._df, self._time_col)
        self._series_combo.configure(values=self._y_cols)
        if self._y_cols:
            self._single_idx = min(self._single_idx, len(self._y_cols) - 1)
            self._series_combo.set(self._y_cols[self._single_idx])
        t = pd.to_numeric(self._df[self._time_col], errors="coerce")
        valid = t[np.isfinite(t)]
        if len(valid):
            self._t_full = (float(valid.min()), float(valid.max()))
        else:
            self._t_full = (0.0, 1.0)

    def _reset_xlim(self) -> None:
        lo, hi = self._t_full
        self._tmin_var.set(f"{lo:.6g}")
        self._tmax_var.set(f"{hi:.6g}")
        self._redraw()

    def _parse_lim(self, s: str) -> float | None:
        s = s.strip()
        if not s:
            return None
        try:
            return float(s)
        except ValueError:
            return None

    def _apply_xlim(self) -> None:
        self._redraw()

    def _clear_fig(self) -> None:
        self._fig.clear()
        self._canvas.draw()

    def _effective_xlim(self) -> tuple[float, float]:
        lo, hi = self._t_full
        tmin = self._parse_lim(self._tmin_var.get())
        tmax = self._parse_lim(self._tmax_var.get())
        if tmin is None:
            tmin = lo
        if tmax is None:
            tmax = hi
        if tmax <= tmin:
            tmax = tmin + 1e-9
        return tmin, tmax

    def _crop_time_limits(self) -> tuple[float, float]:
        """Prefer the on-screen plot X limits (after zoom/pan); else min/max fields."""
        ax_list = self._fig.get_axes() if self._fig is not None else []
        if self._df is not None and self._time_col and len(ax_list) > 0:
            lo, hi = ax_list[0].get_xlim()
            a, b = float(min(lo, hi)), float(max(lo, hi))
            if np.isfinite(a) and np.isfinite(b) and b > a:
                return a, b
        return self._effective_xlim()

    def _crop_current_csv(self) -> None:
        if not self._files or self._df is None or self._time_col is None:
            messagebox.showinfo("Cut", "Nothing loaded.")
            return
        path = self._files[self._index]
        if path.suffix.lower() != ".csv":
            messagebox.showinfo("Cut", "On-disk crop is only supported for CSV files.")
            return

        tmin, tmax = self._crop_time_limits()
        t = pd.to_numeric(self._df[self._time_col], errors="coerce")
        mask = np.isfinite(t) & (t >= tmin) & (t <= tmax)
        n_keep = int(mask.sum())
        if n_keep == 0:
            messagebox.showwarning("Cut", "No rows fall in the current X range.")
            return
        n_drop = int(len(self._df) - n_keep)
        if not messagebox.askyesno(
            "Cut (crop CSV)",
            f"Overwrite file and keep only rows with {self._time_col!r} in [{tmin:g}, {tmax:g}]?\n\n"
            f"Keep: {n_keep} rows\nRemove: {n_drop} rows\n\n{path.name}",
        ):
            return

        cropped = self._df.loc[mask].copy()
        if "t_rel_s" in cropped.columns:
            hu = pd.to_numeric(cropped["host_unix_s"], errors="coerce") if "host_unix_s" in cropped.columns else None
            if hu is not None and hu.notna().any():
                t0 = float(hu.min())
                cropped["t_rel_s"] = hu - t0
            else:
                tr = pd.to_numeric(cropped["t_rel_s"], errors="coerce")
                if tr.notna().any():
                    cropped["t_rel_s"] = tr - tr.min()

        tmp_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                newline="",
                encoding="utf-8",
                delete=False,
                dir=path.parent,
                prefix=f".crop_{path.stem}_",
                suffix=".tmp.csv",
            ) as tmp:
                tmp_path = Path(tmp.name)
                cropped.to_csv(tmp, index=False)
            tmp_path.replace(path)
        except Exception as e:
            if tmp_path is not None:
                try:
                    tmp_path.unlink(missing_ok=True)
                except OSError:
                    pass
            messagebox.showerror("Cut failed", str(e))
            return

        messagebox.showinfo("Cut", f"Saved {n_keep} rows to {path.name}")
        self._reload_df_only()

    def _delete_current_file(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        if not messagebox.askyesno(
            "Delete file",
            f"Permanently delete this file from disk?\n\n{path}",
        ):
            return
        try:
            path.unlink()
        except OSError as e:
            messagebox.showerror("Delete failed", str(e))
            return

        del self._files[self._index]
        if not self._files:
            self._df = None
            self._time_col = None
            self._y_cols = []
            self._file_combo.configure(values=[])
            self._series_combo.configure(values=[])
            self._title_lbl.configure(text="")
            self._clear_fig()
            messagebox.showinfo("Delete", "File removed. No more data files in this folder.")
            return

        if self._index >= len(self._files):
            self._index = len(self._files) - 1
        self._file_combo.configure(values=[self._display_path(p) for p in self._files])
        self._sync_file_combo()
        self._load_current_file()

    def _redraw(self) -> None:
        self._fig.clear()
        if self._df is None or self._time_col is None or not self._y_cols:
            ax = self._fig.add_subplot(1, 1, 1)
            ax.text(0.5, 0.5, "No plottable numeric columns", ha="center", va="center")
            self._canvas.draw()
            return

        df = self._df
        t = pd.to_numeric(df[self._time_col], errors="coerce")
        xlim = self._effective_xlim()

        if self._single_mode.get():
            show = [self._y_cols[self._single_idx]]
        else:
            show = self._y_cols

        n = len(show)
        axes = self._fig.subplots(n, 1, sharex=True, squeeze=False)
        self._fig.suptitle(
            f"{self._title_lbl.cget('text')}  —  time: {self._time_col}",
            fontsize=11,
        )

        for i, col in enumerate(show):
            ax = axes[i, 0]
            y = pd.to_numeric(df[col], errors="coerce")
            mask = np.isfinite(t) & np.isfinite(y)
            if mask.any():
                ax.plot(t.values[mask], y.values[mask], linewidth=0.8)
            ax.set_ylabel(col, fontsize=9)
            ax.grid(True, alpha=0.3)
            ax.set_xlim(xlim)

        axes[-1, 0].set_xlabel(self._time_col)
        self._canvas.draw()


def main() -> None:
    app = DataCaptureViewer()
    app.mainloop()


if __name__ == "__main__":
    main()
